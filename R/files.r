#______________________________________________________________________________
# Uploads and exports for the open project: the main-process parts. The
# file reading and writing is done by `work_import()`, `work_component()`
# and `work_export()` in `R/worker.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Save an uploaded file where a worker can read it.
#' @return The path. The cleanup timer removes it if the job never does.
#' @noRd
save_upload <- function (REQ, upload) {
  infile <- tempfile(pattern = "upload_", tmpdir = REQ[['SESSION']][['server_temp']])
  writeBin(object = upload[['value']], con = infile)
  infile
}


#______________________________________________________________________________
#' Accept a new biom file from the user; switch to that project.
#'
#' @param inflate  Scale counts that are not whole numbers up to whole
#'                 numbers? Without it such a file is refused with the error
#'                 code `confirm_inflate` and a message that explains what
#'                 scaling does, for the browser to put to the user.
#' @return list(BIOM, jstree_node)
#' @noRd
api_upload_biom <- function (REQ, biom_file, inflate = FALSE) {

  infile <- save_upload(REQ, biom_file)

  # Use the file's name as the project's title.
  title <- basename(biom_file[['filename']])
  title <- sub("\\.(biom|txt|tab)\\.*(gz|bz2|)$", "", title)
  title <- substr(title, 0, 100)

  job(
    fn     = "work_import",
    args   = list(ctx = worker_ctx(REQ[['CONFIG']]), infile = infile, title = title, inflate = inflate),
    finish = function (imported) {

      unlink(infile)

      DB         <- REQ[['DB']]
      user_id    <- REQ[['SESSION']][['user_id']]
      session_id <- REQ[['SESSION']][['session_id']]

      project_id <- add_project(REQ, imported)

      # Create and switch to a new draft for this project.
      db_update(
        DB       = DB,
        table    = 'sessions',
        id       = session_id,
        err_code = "AUBiom1",
        draft_id = create_draft(DB, project_id) )

      resume_session(REQ)

      sql <- paste0(
        "SELECT * FROM permissions",
        " LEFT JOIN projects USING (project_id)",
        " WHERE user_id = ? AND project_id = ?" )
      row <- db_query(DB, sql, "AUBiom2", list(user_id, project_id))

      list(
        BIOM        = biom_reply(REQ, imported[['data']]),
        jstree_node = compile_jstree_node(row) )
    })
}


#______________________________________________________________________________
#' Import a metadata csv, taxonomy csv, or newick tree file
#' @return list(BIOM)
#' @noRd
api_upload_component <- function (REQ, component, component_file) {

  infile <- save_upload(REQ, component_file)

  job(
    fn   = "work_component",
    args = list(
      ctx       = worker_ctx(REQ[['CONFIG']]),
      full      = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare      = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      component = component,
      infile    = infile ),
    finish = function (result) {
      unlink(infile)
      update_draft(REQ, full = result[['full']], rare = result[['rare']])
      list(BIOM = biom_reply(REQ, result[['data']]))
    })
}


#______________________________________________________________________________
#' Write part of the open project to a file the browser can download.
#'
#' @param what        `original` (the file as uploaded), `metadata`,
#'                    `taxonomy`, `tree`, `biom`, `alpha` (diversity),
#'                    `beta` (distance matrix), `taxa` (abundances) or
#'                    `xlsx` (an Excel workbook of all of these).
#' @param sample_set  `full` or `rare` (rarefied). `beta` is always
#'                    rarefied, `original` never is, and `xlsx` holds both.
#' @param format      For `biom`: `json`, `hdf5` or `tab`.
#' @param method      For `beta`: the distance metric, one of rbiom's ids.
#' @param rank        For `taxa`: a taxonomic rank of the project.
#' @return list(download_url)
#' @noRd
api_export <- function (REQ, what, sample_set = "full", format = "json", method = "bray", rank = ".otu") {

  DB          <- REQ[['DB']]
  project_id  <- REQ[['SESSION']][['project_id']]
  client_temp <- REQ[['SESSION']][['client_temp']]
  server_temp <- REQ[['SESSION']][['server_temp']]

  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "AExpo1", list(project_id), req1 = TRUE)

  # rbiom writes workbooks with a package it only suggests.
  if (what == "xlsx" && !has_package(rbiom_schema()[['write_xlsx']][['needs']]))
    stop_user("This server cannot make Excel files: the openxlsx package is not installed.")

  if (what == "beta")     sample_set <- "rare"
  if (what == "xlsx")     sample_set <- "full"
  if (what == "original") sample_set <- "orig"

  biom_file_id <- project[[paste0(sample_set, '_bf_id')]]
  rare_file_id <- project[['rare_bf_id']]

  # A file name that says what is inside. A rank is the user's own word, so
  # only its letters, digits and hyphens go into the name.
  file_ext <- switch(what, original = "biom", tree = "tre", biom = format, xlsx = "xlsx", "csv")

  rank_term <- rank
  if (!grepl("^[A-Za-z0-9\\-]+$", rank))
    rank_term <- paste0(
      gsub("[^A-Za-z0-9\\-]+", "", rank),
      substr(as.character(sha256(charToRaw(enc2utf8(rank)))), 1, 8) )

  terms <- switch(
    EXPR     = what,
    original = what,
    beta     = c(what, method, sample_set),
    taxa     = c(what, rank_term, sample_set),
    xlsx     = c(what, "rare", rare_file_id),   # its rarefied sheets depend on the depth
    c(what, sample_set) )

  filepath   <- sprintf("%i/%s_%i.%s", biom_file_id, paste(terms, collapse = "_"), biom_file_id, file_ext)
  server_uri <- paste0(server_temp, "/", filepath)
  resp       <- list('download_url' = unbox(paste0(client_temp, "/", filepath)))

  # Already exported during this session.
  if (file.exists(server_uri)) {
    Sys.setFileTime(server_uri, Sys.time())
    return (resp)
  }

  job(
    fn   = "work_export",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      src         = biom_path(REQ, biom_file_id),
      dest        = server_uri,
      what        = what,
      format      = format,
      method      = method,
      rank        = rank,
      title       = project[['title']],
      description = project[['description']],
      rare        = if (what == "xlsx") biom_path(REQ, rare_file_id) ),
    finish = function (result) resp )
}
