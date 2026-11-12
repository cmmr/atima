#______________________________________________________________________________
# The metadata and taxonomy tables of the open project.
#
# The `api_*()` handlers run in the main process and only describe a job.
# `dt_page()`, `metadata_thead()` and `taxonomy_thead()` are the pure parts
# that a worker applies to the data (`work_table_page()`,
# `work_table_head()` in `R/worker.R`). They build HTML from names and
# values that came out of an uploaded file, so they escape all of them.
#______________________________________________________________________________


#' A job on the session's full (unrarefied) BIOM file.
#' @noRd
full_biom_job <- function (REQ, fn, ...) {
  job(fn, list(
    ctx = worker_ctx(REQ[['CONFIG']]),
    src = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
    ... ))
}


#______________________________________________________________________________
#' Provide server side paging of the METADATA DataTable.
#'
#' @return list(draw, recordsTotal, recordsFiltered, data)
#'         as per https://datatables.net/manual/server-side .
#' @noRd
api_metadata_dt <- function (
    REQ, columns=NULL, draw=1L, start=0L, length=10L,
    search=list(value="", regex=FALSE), order=list(column=0L, dir="asc")) {

  full_biom_job(
    REQ, "work_table_page", what = "metadata",
    draw = draw, start = start, length = length, search = search, order = order )
}


#______________________________________________________________________________
#' Provide server side paging of the TAXONOMY DataTable.
#'
#' @return list(draw, recordsTotal, recordsFiltered, data)
#'         as per https://datatables.net/manual/server-side .
#' @noRd
api_taxonomy_dt <- function (
    REQ, columns=NULL, draw=1L, start=0L, length=10L,
    search=list(value="", regex=FALSE), order=list(column=0L, dir="asc")) {

  full_biom_job(
    REQ, "work_table_page", what = "taxonomy",
    draw = draw, start = start, length = length, search = search, order = order )
}


#______________________________________________________________________________
#' The double header row of the METADATA DataTable.
#' @return list(html)
#' @noRd
api_metadata_thead <- function (REQ) {
  full_biom_job(REQ, "work_table_head", what = "metadata")
}


#______________________________________________________________________________
#' The header row of the TAXONOMY DataTable.
#' @return list(html)
#' @noRd
api_taxonomy_thead <- function (REQ) {
  full_biom_job(REQ, "work_table_head", what = "taxonomy")
}


#______________________________________________________________________________
#' User wants to change numeric <=> categorical.
#' @return list(BIOM)
#' @noRd
api_metadata_change_class <- function (REQ, col_num) {

  job(
    fn   = "work_change_class",
    args = list(
      ctx     = worker_ctx(REQ[['CONFIG']]),
      full    = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare    = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      col_num = col_num ),
    finish = function (result) {
      update_draft(REQ, full = result[['full']], rare = result[['rare']])
      list(BIOM = biom_reply(REQ, result[['data']]))
    })
}


#______________________________________________________________________________
#' Group the samples into clusters and add them to the working copy's
#' metadata as a new categorical field, which plots can then color, facet
#' or test by.
#'
#' @param cluster_fn    `"taxa_clusters"` or `"bdiv_clusters"`.
#' @param cluster_args  Its arguments, as `check_fn_args()` returned them.
#' @param name          The new field's name.
#' @return list(BIOM)
#' @noRd
api_add_clusters <- function (REQ, cluster_fn, name, cluster_args = list()) {

  job(
    fn   = "work_add_clusters",
    args = list(
      ctx          = worker_ctx(REQ[['CONFIG']]),
      full         = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare         = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      cluster_fn   = cluster_fn,
      cluster_args = cluster_args,
      name         = name,
      checked      = !is.null(known_summary(REQ)) ),
    finish = function (result) {
      update_draft(REQ, full = result[['full']], rare = result[['rare']])
      list(BIOM = biom_reply(REQ, result[['data']]))
    })
}


#______________________________________________________________________________
#' Construct the HTML to define the double header row for the
#' METADATA DataTable. Two header rows: Column Name and Column Class.
#'
#' @param df  The metadata table.
#' @return A <thead/> html string.
#' @noRd
metadata_thead <- function (df) {

  colnames <- paste("<th>", html_escape(colnames(df)), "</th>")
  classes  <- sapply(
    X         = seq_len(ncol(df)),
    USE.NAMES = FALSE,
    function (i) {

      vals      <- df[[i]]
      curr_type <- ifelse(is.numeric(vals), "numeric", "categorical")

      if (i == ".sample")
        return (paste0("<td>", curr_type, "</td>"))

      if (!all(is.na(vals) | grepl("^[\\+\\-]{0,1}[0-9]*\\.{0,1}[0-9]*$", vals)))
        return (paste0("<td>", curr_type, "</td>"))

      return (paste0(
        "<td><select class='numcat' data-colnum='", (i - 1), "'>",
        "<option", ifelse(curr_type == "numeric", " selected", ""), ">numeric</option>",
        "<option", ifelse(curr_type == "numeric", "", " selected"), ">categorical</option>",
        "</select></td>" ))
    })

  sprintf(
    fmt = "<thead><tr>%s</tr><tr>%s</tr></thead>",
    paste(colnames, collapse = ""),
    paste(classes, collapse = "") )
}


#______________________________________________________________________________
#' Construct the HTML to define the header row for the dynamically defined
#' TAXONOMY DataTable.
#'
#' @param df  The taxonomy table.
#' @return A <thead/> html string.
#' @noRd
taxonomy_thead <- function (df) {
  colnames <- paste("<th>", html_escape(colnames(df)), "</th>")
  colnames <- paste(colnames, collapse = "")
  sprintf("<thead><tr>%s</tr></thead>", colnames)
}


#______________________________________________________________________________
#' Handle server-side paging of a datatable.
#'
#' DataTables puts the cell values it is sent into the page as HTML, so
#' they are escaped here, after searching and sorting.
#'
#' @return list(draw, recordsTotal, recordsFiltered, data)
#'         as per https://datatables.net/manual/server-side . The values in
#'         `data` are HTML-escaped strings.
#' @noRd
dt_page <- function (
    df, draw=1L, start=0L, length=10L,
    search=list(value="", regex=FALSE), order=list(column=0L, dir="asc")) {


  df <- if (is.matrix(df)) df else as.matrix(df)
  recordsTotal <- nrow(df)

  # Coerce inputs into expected formats
  draw   <- as.integer(draw)
  start  <- as.integer(start) + 1
  length <- as.integer(length)

  # Filter by global search term
  if (!identical(search[['value']], "")) {
    pattern <- tolower(head(as.character(search[['value']]), 1))
    df      <- df[apply(tolower(as.matrix(df)), 1L, function (row) {
      any(grepl(pattern, row, fixed = TRUE)) }),,drop=FALSE]
  }
  recordsFiltered <- nrow(df)

  # Sort by the `order` arguments: one row per sort column.
  order <- as.data.frame(order, stringsAsFactors = FALSE)
  for (i in seq_len(nrow(order))) {
    column     <- head(as.integer(order[i,'column']), 1) + 1
    decreasing <- identical(order[i,'dir'], "desc")
    if (is.na(column) || column < 1 || column > ncol(df))
      stop_user("There is no column ", column, " to sort by.")
    df <- df[base::order(df[,column], decreasing = decreasing),,drop=FALSE]
  }

  # Hand back just a page's worth of rows.
  rows <- seq_len(nrow(df))
  df   <- df[rows >= start & rows < start + length,,drop=FALSE]
  df[] <- html_escape(df)

  return (list(
    draw            = unbox(as.integer(draw)),
    recordsTotal    = unbox(recordsTotal),
    recordsFiltered = unbox(recordsFiltered),
    data            = df ))
}
