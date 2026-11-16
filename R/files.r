#______________________________________________________________________________
# Uploads and exports for the open project: the main-process parts. The
# file reading and writing is done by `work_import()`, `work_component()`
# and `work_export()` in `R/worker.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Save an uploaded file where a worker can read it.
#' @return The path. The handler removes the file when its job ends, and
#'         the cleanup timer does if the server stopped before that.
#' @noRd
save_upload <- function (REQ, upload) {
  infile <- tempfile(pattern = "upload_", tmpdir = REQ[['SESSION']][['server_temp']])
  writeBin(object = upload[['value']], con = infile)
  infile
}


#______________________________________________________________________________
#' What to do when the job that reads an upload fails: remove the file, and
#' let the router answer as it does for any error.
#' @return A function for `job()`'s `failed`.
#' @noRd
upload_failed <- function (infile) {
  function (e) {
    unlink(infile)
    stop(e)
  }
}


#______________________________________________________________________________
#' The largest upload the server accepts, in megabytes (`run()`'s
#' `max_upload_mb`).
#' @noRd
max_upload_mb <- function (CONFIG) {
  as.integer(CONFIG[['max_upload_mb']] %||% 50L)
}


#______________________________________________________________________________
#' A project title from an uploaded file's name: the name without its
#' directory, its file type and its compression ("gut study.biom.gz" gives
#' "gut study").
#' @noRd
upload_title <- function (filename) {
  title <- basename(filename)
  title <- sub("\\.(gz|bz2)$", "", title, ignore.case = TRUE)
  title <- sub("\\.(biom|txt|tab|tsv|csv|json|hdf5|h5|qza|shared)$", "", title, ignore.case = TRUE)
  substr(title, 1, 100)
}


#______________________________________________________________________________
#' Accept a file from the user as a new project; switch to that project.
#'
#' The file is a BIOM file, a QIIME 2 feature table (`.qza`), a mothur
#' `.shared` file or a table of counts in delimited text (`R/import.R`).
#'
#' @param inflate  Scale counts that are not whole numbers up to whole
#'                 numbers? Without it such a file is refused with the error
#'                 code `confirm_inflate` and a message that explains what
#'                 scaling does, for the browser to put to the user.
#' @return list(BIOM, tree_node, notes). `notes` is what the user should
#'         know about the file that was read; see `work_import()`.
#' @noRd
api_upload_biom <- function (REQ, biom_file, inflate = FALSE) {

  infile <- save_upload(REQ, biom_file)

  # Use the file's name as the project's title.
  title <- upload_title(biom_file[['filename']])

  job(
    fn     = "work_import",
    args   = list(
      ctx      = worker_ctx(REQ[['CONFIG']]),
      infile   = infile,
      title    = title,
      inflate  = inflate,
      filename = biom_file[['filename']] ),
    failed = upload_failed(infile),
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
        BIOM      = biom_reply(REQ, imported[['data']]),
        tree_node = tree_node(row),
        notes     = as.character(imported[['notes']]) )
    })
}


#______________________________________________________________________________
#' Replace the working copy's metadata, taxonomy or tree with a file: a
#' table for the first two (the taxonomy also as a QIIME 2 artifact), a
#' Newick tree or a QIIME 2 phylogeny artifact for the third.
#' @return list(BIOM, notes). `notes` says what the new part made the
#'         project lose, such as samples the new metadata does not list.
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
      infile    = infile,
      filename  = component_file[['filename']] ),
    failed = upload_failed(infile),
    finish = function (result) {
      unlink(infile)
      update_draft(REQ, full = result[['full']], rare = result[['rare']])
      list(
        BIOM  = biom_reply(REQ, result[['data']]),
        notes = as.character(result[['notes']]) )
    })
}


#______________________________________________________________________________
# Everything `api_export()` can be asked for.
export_whats <- c(
  "original", "metadata", "taxonomy", "tree", "biom", "alpha", "beta", "taxa",
  "xlsx", "qiime2", "mothur", "phyloseq" )

# What the exports that need a package make, as an error message calls it.
export_makes <- list(
  xlsx     = "Excel files",
  qiime2   = "zip files",
  mothur   = "zip files",
  phyloseq = "phyloseq files" )


#' The packages an export needs that atima does not import.
#' @return A character vector; empty for most exports.
#' @noRd
export_needs <- function (what) {
  switch(
    EXPR     = what,
    xlsx     = as.character(unlist(rbiom_schema()[['write_xlsx']][['needs']])),
    qiime2   = "zip",
    mothur   = "zip",
    phyloseq = "phyloseq",
    character(0) )
}


#' The exports this server can make: all of them, less those that need a
#' package it does not have. The browser and the MCP tool offer only these.
#' @noRd
export_choices <- function () {
  schema_once("exports", Filter(x = export_whats, function (what) {
    all(vapply(export_needs(what), has_package, logical(1))) }))
}


#' The file extension of an export.
#' @param format  For `biom`: `json`, `hdf5` or `tab`.
#' @noRd
export_ext <- function (what, format = "json") {
  switch(
    EXPR     = what,
    tree     = "tre",
    biom     = format,
    xlsx     = "xlsx",
    qiime2   = "zip",
    mothur   = "zip",
    phyloseq = "rds",
    "csv" )
}


#______________________________________________________________________________
#' Write part of the open project to a file the browser can download.
#'
#' @param what        `original` (the file as uploaded), `metadata`,
#'                    `taxonomy`, `tree`, `biom`, `alpha` (diversity),
#'                    `beta` (distance matrix), `taxa` (abundances),
#'                    `xlsx` (an Excel workbook of all of these), `qiime2`
#'                    or `mothur` (a zip of the files that program reads)
#'                    or `phyloseq` (a phyloseq object, as `.rds`).
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

  # Some exports are written with a package that is only suggested.
  needs   <- export_needs(what)
  missing <- needs[!vapply(needs, has_package, logical(1))]
  if (length(missing) > 0)
    stop_user(
      "This server cannot make ", export_makes[[what]], ": the ", missing[[1]],
      " package is not installed.")

  if (what == "beta")     sample_set <- "rare"
  if (what == "xlsx")     sample_set <- "full"
  if (what == "original") sample_set <- "orig"

  biom_file_id <- project[[paste0(sample_set, '_bf_id')]]
  rare_file_id <- project[['rare_bf_id']]

  # A file name that says what is inside. A rank is the user's own word, so
  # only its letters, digits and hyphens go into the name.
  file_ext <- if (what == "original") "biom" else export_ext(what, format)

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
    cpus   = export_cpus(what),
    finish = function (result) resp )
}
