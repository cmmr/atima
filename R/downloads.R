#______________________________________________________________________________
# BIOM file downloads.
#
#   GET /<access_key>/rare.json.gz
#   GET /unsaved/<session_key>/full.json
#
# These URLs appear in the R code that atima shows next to a plot, so they
# are fetched by R scripts that carry no cookie. Whoever knows a project's
# access key may read it, which is the same rule `api_init_session()`
# applies when a browser opens a project by its key.
#______________________________________________________________________________


#______________________________________________________________________________
#' Download a saved project's BIOM file.
#' @return <response> with the file as its body.
#' @noRd
download_project_biom <- function (REQ, access_key, file) {

  DB <- REQ[['DB']]

  sql <- paste0(
    "SELECT project_id, full_bf_id, rare_bf_id, title, description",
    " FROM projects WHERE access_key = ?" )
  project <- db_query(DB, sql, "DPBiom1", list(access_key), simplify = FALSE)

  if (nrow(project) != 1)
    stop_not_found("Project not found.")

  project <- as.list(project)

  if (!is_project_readable(DB, project[['project_id']], user_id = NULL, access_key = access_key))
    stop_not_found("Project not found.")

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
  draft <- db_query(DB, sql, "DDBiom1", list(session_key), simplify = FALSE)

  if (nrow(draft) != 1)
    stop_not_found("Project not found.")

  biom_response(REQ, as.list(draft), file)
}


#______________________________________________________________________________
#' Write a BIOM object in the requested format and send it.
#'
#' @param project  A list with `full_bf_id`, `rare_bf_id`, `title` and
#'                 `description`.
#' @param file     `<rare|full>.<tab|json|hdf5>[.gz|.bz2]`, already checked
#'                 by the router.
#' @noRd
biom_response <- function (REQ, project, file) {

  TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]

  parts        <- strsplit(file, ".", fixed = TRUE)[[1]]
  biom_file_id <- project[[paste0(parts[[1]], '_bf_id')]]
  format       <- parts[[2]]


  #________________________________________________________
  # Add the latest title and description to the biom obj.
  #________________________________________________________
  biom         <- get_biom(REQ, biom_file_id)
  biom$id      <- project[['title']]
  biom$comment <- paste0(collapse = '\n', pandoc_convert(
    text = project[['description']], from = 'html', to = 'markdown' ))


  #________________________________________________________
  # Use rbiom to write to a temporary file. The extension
  # tells rbiom which compression to use.
  #________________________________________________________
  tfile <- tempfile(tmpdir = TEMP_DIR, fileext = sub("^[a-z]+", "", file))
  on.exit(unlink(tfile), add = TRUE)
  write_biom(biom, tfile, format)

  content_type <- switch(
    EXPR   = tail(parts, 1),
    'gz'   = 'application/gzip',
    'bz2'  = 'application/x-bzip2',
    'tab'  = 'text/plain; charset=utf-8',
    'json' = 'application/json; charset=utf-8',
    'application/octet-stream' )

  structure(
    class = c('response', 'AsIs'),
    .Data = list(
      status  = 200L,
      headers = list(
        'Content-Type'           = content_type,
        'Content-Disposition'    = paste0('attachment; filename="', file, '"'),
        'X-Content-Type-Options' = 'nosniff' ),
      body    = read_file_raw(tfile) ))
}
