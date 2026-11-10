#______________________________________________________________________________
#' Update the rarefaction level.
#' @return list(BIOM) or list()
#' @noRd
api_rarefy <- function (REQ, depth) {
  
  if (rarefy_if_needed(REQ, depth)) {
    
    resume_session(REQ)
    BIOM <- get_biom_data(REQ)
    return (list(BIOM = BIOM))
    
  } else {
    return (list())
  }
  
  
  
}


#______________________________________________________________________________
#' Overwrites the original project with the working draft.
#' @return list(BIOM)
#' @noRd
api_save <- function (REQ, title, access_key, description) {
  
  sanity_check(title, access_key, description)
  
  DB         <- REQ[['DB']]
  user_id    <- REQ[['SESSION']][['user_id']]
  draft_id   <- REQ[['SESSION']][['draft_id']]
  project_id <- REQ[['SESSION']][['project_id']]
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  
  #________________________________________________________
  # Verify editor permissions on the parent.
  #________________________________________________________
  is_project_writable(DB, project_id, user_id, assert = TRUE)
  
  
  #________________________________________________________
  # Check that new custom access_key is valid and available.
  #________________________________________________________
  if (!identical(access_key, REQ[['SESSION']][['access_key']]))
    access_key <- create_access_key(DB, requested_access_key = access_key)
  
  
  #________________________________________________________
  # Copy data from draft to parent project.
  #________________________________________________________
  full_biom <- get_biom(REQ, full_bf_id)
  details   <- biom_to_details(full_biom)
  
  db_update(
    DB            = DB, 
    table         = "projects", 
    id            = project_id, 
    err_code      = "ASave1",
    title         = title,
    full_bf_id    = full_bf_id,
    rare_bf_id    = rare_bf_id,
    access_key    = access_key,
    description   = description,
    n_samples     = details[['n_samples']],
    n_taxa        = details[['n_taxa']],
    has_tree      = details[['has_tree']],
    median_depth  = details[['median_depth']],
    meta_colnames = details[['meta_colnames']] %>% toJSON() )
  
  
  #________________________________________________________
  # Reload this project on the client side.
  #________________________________________________________
  resume_session(REQ)
  BIOM <- get_biom_data(REQ)
  
  
  return (list(BIOM = BIOM))
}


#______________________________________________________________________________
#' Copy this draft to a new project_id.
#' 
#' @return list(BIOM, jstree_node)
#' @noRd
api_save_as <- function (REQ, title, access_key, description) {
  
  DB         <- REQ[['DB']]
  user_id    <- REQ[['SESSION']][['user_id']]
  draft_id   <- REQ[['SESSION']][['draft_id']]
  project_id <- REQ[['SESSION']][['project_id']]
  full_name  <- REQ[['SESSION']][['full_name']]
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  sanity_check(title, access_key, description)
  
  
  #________________________________________________________
  # Get a new unique access_key.
  #________________________________________________________
  access_key <- create_access_key(DB, requested_access_key = access_key)
  
  
  #________________________________________________________
  # Fetch the current project values.
  #________________________________________________________
  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "ASAs2", list(project_id), req1 = TRUE)
  
  full_biom <- get_biom(REQ, full_bf_id)
  details   <- biom_to_details(full_biom)
  
  
  #________________________________________________________
  # Merge into a new project record.
  #________________________________________________________
  project_id <- db_insert(
    DB            = DB,
    table         = "projects",
    err_code      = "ASAs3",
    project_id    = NULL,
    defaults      = project,
    title         = title,
    full_bf_id    = full_bf_id,
    rare_bf_id    = rare_bf_id,
    access_key    = access_key,
    description   = description,
    n_samples     = details[['n_samples']],
    n_taxa        = details[['n_taxa']],
    has_tree      = details[['has_tree']],
    median_depth  = details[['median_depth']],
    meta_colnames = details[['meta_colnames']] %>% toJSON(),
    editors       = toJSON(full_name),
    n_views       = 1L )
  
  
  #________________________________________________________
  # Update the draft to point to the new project.
  #________________________________________________________
  sql <- "UPDATE drafts set project_id = ? WHERE draft_id = ?"
  db_query(DB, sql, "ASAs4", list(project_id, draft_id))
  
  
  #________________________________________________________
  # Grant editor permissions to this user.
  #________________________________________________________
  sql <- "INSERT INTO permissions (user_id, project_id) VALUES (?, ?)"
  permission_id <- db_query(DB, sql, "ASAs5", list(user_id, project_id))
  
  sql <- "INSERT INTO last_access (user_id, project_id) VALUES (?, ?)"
  db_query(DB, sql, "ASAs6", list(user_id, project_id))
  
  
  #________________________________________________________
  # Fetch information for displaying in the collections.
  #________________________________________________________
  sql <- paste0(
    "SELECT * FROM permissions",
    " LEFT JOIN projects USING (project_id)",
    " WHERE permission_id = ?" )
  row         <- db_query(DB, sql, "ASAs7", list(permission_id))
  jstree_node <- compile_jstree_node(DB, row)
  
  
  #________________________________________________________
  # Reload this project on the client side.
  #________________________________________________________
  resume_session(REQ)
  BIOM <- get_biom_data(REQ)
  
  
  return (list(BIOM = BIOM, jstree_node = jstree_node))
}


#______________________________________________________________________________
#' Changes the project associated with the current session. 
#' @return invisible(NULL)
#' @noRd
select_project <- function (REQ, project_id = NULL, access_key = NULL) {
  
  DB         <- REQ[['DB']]
  user_id    <- REQ[['SESSION']][['user_id']]
  session_id <- REQ[['SESSION']][['session_id']]
  
  
  if (!is.null(access_key)) {
    sql <- 'SELECT project_id FROM projects WHERE access_key = ?'
    project_id <- db_query(DB, sql, "SProj1", list(access_key))
    if (is.null(project_id)) stop('Project Not Found')
  }
  
  
  
  # Confirms that the user is allowed to access this project
  is_project_readable(DB, project_id, user_id, assert=TRUE)
  
  # Create a new draft for this project.
  db_update(
    DB       = DB, 
    table    = 'sessions', 
    id       = session_id, 
    err_code = "SProj2",
    draft_id = create_draft(DB, project_id) )
  
  resume_session(REQ)
  
  invisible()
}



#______________________________________________________________________________
#' Parse out summary information from a biom file to go into `projects`. 
#' @return list(title, description, n_samples, ...)
#' @noRd
biom_to_details <- function (biom) {
  
  list(
    title         = biom$id,
    description   = pandoc_convert(text = biom$comment, to = 'html', args = '--wrap=none'),
    n_samples     = biom$n_samples,
    n_taxa        = biom$n_otus,
    has_tree      = !is.null(biom$tree),
    median_depth  = as.integer(median(sample_sums(biom))),
    meta_colnames = biom$fields )
}



#______________________________________________________________________________
#' Insert a new project into the SQL tables. 
#' @return a project_id.
#' @noRd
add_project <- function (REQ, infile, title = NULL, collection_id = NULL, requested_access_key = NULL) {
  
  DB        <- REQ[['DB']]
  user_id   <- REQ[['SESSION']][['user_id']]
  full_name <- REQ[['SESSION']][['full_name']]
  
  
  #________________________________________________________
  # Parse the BIOM data into full and rarefied objects
  #________________________________________________________
  full_biom <- as_rbiom(infile)
  
  full_biom$sequences <- NULL
  if (!is.null(title)) full_biom$id <- title
  
  rare_biom <- rarefy(full_biom)
  details   <- biom_to_details(full_biom)
  
  
  #________________________________________________________
  # Save to `projects` and `objects` SQL tables.
  #________________________________________________________
  project_id <- db_insert(
    DB            = DB,
    table         = "projects",
    err_code      = "AProj1",
    title         = details[['title']],
    orig_bf_id    = store_file(REQ, infile), 
    full_bf_id    = store_biom(REQ, full_biom), 
    rare_bf_id    = store_biom(REQ, rare_biom), 
    access_key    = create_access_key(DB, requested_access_key), 
    description   = details[['description']],
    n_samples     = details[['n_samples']],
    n_taxa        = details[['n_taxa']],
    has_tree      = details[['has_tree']],
    median_depth  = details[['median_depth']],
    meta_colnames = details[['meta_colnames']] %>% toJSON(),
    editors       = toJSON(full_name) )
  
  
  #________________________________________________________
  # Put into the user's top level collection by default.
  #________________________________________________________
  db_insert(DB, "permissions", "AProj2", project_id, user_id, collection_id)
  
  
  return (project_id)
}



#______________________________________________________________________________
#' Copy an existing project to a working draft.
#' 
#' @return draft_id
#' @noRd
create_draft <- function (DB, project_id) {
  
  
  #________________________________________________________
  # Increment this project's number of views.
  #________________________________________________________
  sql <- "UPDATE projects SET n_views = n_views + 1 WHERE project_id = ?"
  db_query(DB, sql, "CDraf1", list(project_id))
  
  
  #________________________________________________________
  # Get the project data for copying to a draft.
  #________________________________________________________
  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "CDraf2", list(project_id), req1 = TRUE)
    
  
  #________________________________________________________
  # Duplicate the project to a draft.
  #________________________________________________________
  draft_id <- db_insert(
    DB         = DB, 
    table      = "drafts", 
    err_code   = "OProj2",
    project_id = project_id,
    full_bf_id = project[['full_bf_id']],
    rare_bf_id = project[['rare_bf_id']] )
  
  return (draft_id)
}



#______________________________________________________________________________
#' Generate a new random string starting with a letter, unique in DB. 
#' @return an access_key
#' @noRd
create_access_key <- function (DB, requested_access_key = NULL) {
  
  
  #________________________________________________________
  # Ignore malformed requested_access_keys
  #________________________________________________________
  if (sanity_check(requested_access_key, assert = FALSE)) {
    access_key <- requested_access_key
  } else {
    access_key <- random_string(12)
  }
  
  
  #________________________________________________________
  # Try again on key collision
  #________________________________________________________
  for (i in 1:10) {
    
    # This is a valid access_key; return it.
    sql <- "SELECT COUNT(*) FROM projects WHERE access_key = ?"
    if (db_query(DB, sql, "CAKey1", list(access_key)) == 0)
      return (access_key)
    
    # Generate another random key.
    access_key <- random_string(12)
  }
  
  stop("Unable to generate a unique access key.")
}



#______________________________________________________________________________
#' Check if this user is allowed to view this project.
#' @noRd
is_project_readable <- function (DB, project_id, user_id, access_key=NULL, assert=FALSE) {
  
  if (!sanity_check(access_key, assert = assert))
    return (FALSE)
  
  sql <- paste0(
    "SELECT COUNT(*) FROM permissions",
    " WHERE project_id = ? AND (user_id = ? OR user_id = 0)" )
  res <- db_query(DB, sql, "PRead1", list(project_id, user_id))
  if (res > 0) return (TRUE)
  
  if (!is.null(access_key)) {
    sql <- "SELECT COUNT(*) FROM projects WHERE project_id = ? AND access_key = ?"
    res <- db_query(DB, sql, "PRead2", list(project_id, access_key))
    if (res > 0) return (TRUE)
  }
  
  if (isTRUE(assert))
    stop("Insufficient permissions. Please select a different project.", call. = FALSE)
  
  return (FALSE)
}


#______________________________________________________________________________
#' Check if this user has editor permission on a given project_id.
#' 
#' @return TRUE/FALSE
#' @noRd
is_project_writable <- function (DB, project_id, user_id, assert=FALSE) {
  
  sql <- "SELECT COUNT(*) FROM permissions WHERE project_id = ? AND user_id = ? AND is_editor = 1"
  res <- db_query(DB, sql, "PWrit1", list(project_id, user_id))
  if (res != 1 && isTRUE(assert))
    stop("Insufficient permissions. Please use 'Save As' instead.", call. = FALSE)
  return (res > 0)
}





#______________________________________________________________________________
#' Ensures that rare_biom is rarefied to a specific depth.
#' Keeps back-end and front-end in sync, in case of api_rarefy abort.
#' 
#' @return TRUE if depth was updated, FALSE otherwise.
#' @noRd
rarefy_if_needed <- function (REQ, depth) {
  
  DB         <- REQ[['DB']]
  draft_id   <- REQ[['SESSION']][['draft_id']]
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  new_depth <- int(depth)
  old_depth <- int(get_biom_component(REQ, rare_bf_id, 'depth'))
  
  #________________________________________________________
  # Re-rarefy from the full_biom. Save new rare_biom.
  #________________________________________________________
  if (!identical(new_depth, old_depth)) {
    
    biom <- get_biom(REQ, full_bf_id)
    rarefy(biom, depth = new_depth, clone = FALSE)
    rare_bf_id <- store_biom(REQ, biom)
    
    sql <- "UPDATE drafts SET rare_bf_id = ? WHERE draft_id = ?"
    db_query(DB, sql, "Rare1", list(rare_bf_id, draft_id))
    
    return (TRUE)
  }
  
  
  return (FALSE)
}

