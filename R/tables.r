
#______________________________________________________________________________
#' Provide server side paging of the METADATA DataTable.
#' 
#' @return list(draw, recordsTotal, recordsFiltered, data)
#'         as per https://datatables.net/manual/server-side .
#' @noRd
api_metadata_dt <- function (
    REQ, columns=NULL, draw=1L, start=0L, length=10L, 
    search=list(value="", regex=FALSE), order=list(column=0L, dir="asc")) {
  
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  
  df <- get_biom_component(REQ, full_bf_id, "metadata")
  
  return (dt_page(df, draw, start, length, search, order))
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
  
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  
  df <- get_biom_component(REQ, full_bf_id, "taxonomy")
  
  return (dt_page(df, draw, start, length, search, order))
}



#______________________________________________________________________________
#' Construct the HTML to define the double header row for the 
#' METADATA DataTable. Two header rows: Column Name and Column Class.
#' 
#' @return A <thead/> html string.
#' @noRd
api_metadata_thead <- function (REQ) {
  
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  
  df <- get_biom_component(REQ, full_bf_id, "metadata")
  
  colnames <- paste("<th>", colnames(df), "</th>")
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
  
  html <- sprintf(
    fmt = "<thead><tr>%s</tr><tr>%s</tr></thead>", 
    paste(colnames, collapse = ""), 
    paste(classes, collapse = "") )
  
  return (list(html = unbox(html)))
}



#______________________________________________________________________________
#' Construct the HTML to define the header row for the dynamically defined
#' TAXONOMY DataTable.
#' 
#' @return A <thead/> html string.
#' @noRd
api_taxonomy_thead <- function (REQ) {
  
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  
  df <- get_biom_component(REQ, full_bf_id, "taxonomy")
  
  colnames <- paste("<th>", colnames(df), "</th>")
  colnames <- paste(colnames, collapse = "")
  html     <- sprintf("<thead><tr>%s</tr></thead>", colnames)
  
  return (list(html = unbox(html)))
}



#______________________________________________________________________________
#' User wants to change numeric <=> categorical.
#' @return list(BIOM)
#' @noRd
api_metadata_change_class <- function (REQ, col_num) {
  
  stopifnot(is_scalar_integer(col_num <- int(col_num)))
  stopifnot(isTRUE(col_num > 0))
  
  DB         <- REQ[['DB']]
  draft_id   <- REQ[['SESSION']][['draft_id']]
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  full_biom  <- get_biom(REQ, full_bf_id)
  rare_biom  <- get_biom(REQ, rare_bf_id)
  md         <- full_biom$metadata
  depth      <- rare_biom$depth
  
  stopifnot(isTRUE(col_num > 1 && col_num <= ncol(md)))
  
  if (is.numeric(md[[col_num]])) {
    md[[col_num]] <- as.character(md[[col_num]])
  } else {
    md[[col_num]] <- as.numeric(as.character(md[[col_num]]))
  }
  
  full_biom$metadata <- md
  rare_biom <- rarefy(biom = full_biom, depth = depth)
  
  db_update(
    DB         = DB, 
    table      = "drafts", 
    id         = draft_id, 
    err_code   = "AMCClas1", 
    full_bf_id = store_biom(REQ, full_biom), 
    rare_bf_id = store_biom(REQ, rare_biom) )
  
  resume_session(REQ)
  BIOM <- get_biom_data(REQ)
  
  return (list(BIOM = BIOM))
}



#______________________________________________________________________________
#' Handle server-side paging of a datatable.
#' 
#' @return list(draw, recordsTotal, recordsFiltered, data)
#'         as per https://datatables.net/manual/server-side .
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
  
  # Sort by the `order` arguments
  for (i in seq_len(nrow(order))) {
    column     <- head(as.integer(order[i,'column']), 1) + 1
    decreasing <- identical(order[i,'dir'], "desc")
    df <- df[base::order(df[,column], decreasing = decreasing),,drop=FALSE]
  }
  
  # Hand back just a page's worth of rows.
  if (nrow(df) > length)
    df <- df[start:min(start+length, nrow(df)),,drop=FALSE]
  
  return (list(
    draw            = unbox(as.integer(draw)),
    recordsTotal    = unbox(recordsTotal),
    recordsFiltered = unbox(recordsFiltered),
    data            = df ))
}



