#______________________________________________________________________________
# BIOM file downloads.
#
#   GET /<access_key>/rare.json.gz
#   GET /unsaved/<session_key>/full.json
#
# These URLs appear in the R code that atima shows next to a plot, so they
# are fetched by R scripts that carry no cookie. The key in the URL is the
# permission: a project's public or private key, or the key of the session
# whose working copy it is. The router checks it (the `project_key` and
# `draft_key` rules in `R/access.R`) before these handlers run.
#______________________________________________________________________________


#______________________________________________________________________________
#' Download a saved project's BIOM file.
#' @return <response> with the file as its body.
#' @noRd
download_project_biom <- function (REQ, access_key, file) {

  DB <- REQ[['DB']]

  sql <- paste0(
    "SELECT full_bf_id, rare_bf_id, title, description",
    " FROM projects WHERE project_id = ?" )
  project_id <- key_project(DB, access_key)[['project_id']]
  project    <- db_query(DB, sql, "DPBiom1", list(project_id), req1 = TRUE)

  biom_response(REQ, project, file)
}


#______________________________________________________________________________
#' Download the working copy of a project from an open session.
#' @return <response> with the file as its body.
#' @noRd
download_draft_biom <- function (REQ, session_key, file) {

  DB <- REQ[['DB']]

  sql <- paste0(
    "SELECT",
    "   drafts.full_bf_id    AS full_bf_id,",
    "   drafts.rare_bf_id    AS rare_bf_id,",
    "   projects.title       AS title,",
    "   projects.description AS description",
    " FROM sessions",
    "   JOIN drafts   USING (draft_id)",
    "   JOIN projects USING (project_id)",
    " WHERE session_key = ? AND logout_utc IS NULL" )
  draft <- db_query(DB, sql, "DDBiom1", list(session_key), req1 = TRUE)

  biom_response(REQ, draft, file)
}


#______________________________________________________________________________
#' Have a worker write a BIOM file in the requested format, then send it.
#'
#' @param project  A list with `full_bf_id`, `rare_bf_id`, `title` and
#'                 `description`.
#' @param file     `<rare|full>.<tab|json|hdf5>[.gz|.bz2]`, already checked
#'                 by the router.
#' @return A job whose result is a <response> with the file as its body.
#' @noRd
biom_response <- function (REQ, project, file) {

  parts        <- strsplit(file, ".", fixed = TRUE)[[1]]
  biom_file_id <- project[[paste0(parts[[1]], '_bf_id')]]

  content_type <- switch(
    EXPR   = tail(parts, 1),
    'gz'   = 'application/gzip',
    'bz2'  = 'application/x-bzip2',
    'tab'  = 'text/plain; charset=utf-8',
    'json' = 'application/json; charset=utf-8',
    'application/octet-stream' )

  job(
    fn   = "work_download",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      src         = biom_path(REQ, biom_file_id),
      dir         = file.path(REQ[['CONFIG']][['temp_dir']], "downloads"),
      file        = file,
      title       = project[['title']],
      description = project[['description']] ),
    finish = function (result) {

      path <- result[['path']]
      on.exit(unlink(path), add = TRUE)

      structure(
        class = c('response', 'AsIs'),
        .Data = list(
          status  = 200L,
          headers = list(
            'Content-Type'           = content_type,
            'Content-Disposition'    = paste0('attachment; filename="', file, '"'),
            'X-Content-Type-Options' = 'nosniff' ),
          body    = read_file_raw(path) ))
    })
}


#______________________________________________________________________________
#' The entire contents of a file as a raw vector.
#' @return a raw vector; `raw(0)` if the file does not exist.
#' @noRd
read_file_raw <- function (file) {
  if (!file.exists(file)) return (raw(0))
  readBin(file, what = 'raw', n = file.size(file))
}
