
#______________________________________________________________________________
#' Serves direct-to-client biom files.
#' 
#' For example:
#' /HMP50/rare.json.gz
#' /unsaved/KADFq33aW2/full.json
#' 
#' @return list(headers, status, body)
handle_get_request <- function (REQ) {
  
  DB       <- REQ[['DB']]
  TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]
  PATH     <- REQ[['PATH']]
  
  
  #________________________________________________________
  # Split URL path into words.
  #________________________________________________________
  p <- strsplit(PATH, '/', fixed = TRUE)[[1]]
  p <- p[nzchar(p)]
  
  
  
  #________________________________________________________
  # Pull biom_file_ids either from projects or drafts.
  #________________________________________________________
  filename <- NULL
  project  <- NULL
  
  if (identical(p[[1]], "unsaved")) {
    
    session_key <- p[[2]]
    filename   <- p[[3]]
    
    sql <- paste0(
      "SELECT",
      "   drafts.full_bf_id    as full_bf_id,",
      "   drafts.rare_bf_id    as rare_bf_id,",
      "   projects.title       as title,",
      "   projects.description as description",
      " FROM sessions",
      "   LEFT JOIN drafts   USING (draft_id)",
      "   LEFT JOIN projects USING (project_id)",
      " WHERE session_key = ?" )
    project <- db_query(DB, sql, "SBFile1", list(session_key), req1 = TRUE)
    
  } else {
    
    access_key <- p[[1]]
    filename   <- p[[2]]
    
    sql <- paste0(
      "SELECT full_bf_id, rare_bf_id, title, description",
      " FROM projects WHERE access_key = ?" )
    project <- db_query(DB, sql, "SBFile2", list(access_key), req1 = TRUE)
  }
  
  
  
  #________________________________________________________
  # Make sure that we understand what content/format they want.
  #             object          format          suffix
  if (!grepl("^(rare|full)\\.(tab|json|hdf5)(|\\.gz|\\.bz2)$", filename))
    stop("Invalid format for biom filename: ", filename)
  
  fn_parts     <- strsplit(filename, ".", fixed = TRUE)[[1]]
  biom_file_id <- project[[paste0(fn_parts[[1]], '_bf_id')]]
  format       <- fn_parts[[2]]
  
  
  
  #________________________________________________________
  # Add the latest title and description to the biom obj.
  #________________________________________________________
  biom         <- get_biom(REQ, biom_file_id)
  biom$id      <- project[['title']]
  biom$comment <- paste0(collapse = '\n', pandoc_convert(
    text = project[['description']], from = 'html', to = 'markdown' ))
  
  
  
  #________________________________________________________
  # Use rbiom to write to a temporary file.
  #________________________________________________________
  tfile <- tempfile(tmpdir = TEMP_DIR)
  on.exit(unlink(tfile), add = TRUE)
  write_biom(biom, tfile, format)
  tsize <- file.info(tfile)[['size']]
  
  
  
  headers <- list(
    'Content-Disposition' = 'attachment',
    'Content-Type'        = switch(
      EXPR   = tail(fn_parts, 1), 
      'gz'   = 'application/gzip',
      'bz2'  = 'application/x-bzip2',
      'tab'  = 'text/plain',
      'json' = 'application/json',
      'application/octet-stream' ))
  
  body <- switch(
    EXPR   = tail(fn_parts, 1), 
    'tab'  = readChar(tfile, tsize),
    'json' = readChar(tfile, tsize),
    readBin(tfile, "raw", tsize) )
  
  resp <- I(list(
    status  = 200L,
    headers = headers,
    body    = body ))
  
  return (resp)
}
