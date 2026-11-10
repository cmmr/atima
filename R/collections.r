
#______________________________________________________________________________
#' Open the project that the user selected.
#' @return list(BIOM)
api_jstree_select <- function (REQ, node_id) {
  
  DB <- REQ[['DB']]
  
  sanity_check(node_id)
  stopifnot(startsWith(node_id, "P"))
  
  # Convert node_id -> permission_id -> project_id
  permission_id <- int(substr(node_id, 2, nchar(node_id)))
  sql           <- "SELECT project_id FROM permissions WHERE permission_id = ?"
  project_id    <- db_query(DB, sql, "AJSele1", list(permission_id))
  
  select_project(REQ, project_id = project_id)
  BIOM <- get_biom_data(REQ)
  
  return (list(BIOM = BIOM))
}



#______________________________________________________________________________
#' Generate the tree data for the public and private jsTree collections.
#' 
#' @return an array of node definitions, already unboxed.
compile_jstree_data <- function (REQ) {
  
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  
  # $('#public_collections').jstree({ 'core' : {
  #   'data' : [
  #     { "id" : "C1", "parent" : "#",  "text" : "Collection 1" },
  #     { "id" : "C2", "parent" : "#",  "text" : "Collection 2" },
  #     { "id" : "P1", "parent" : "C2", "text" : "Project 1" },
  #     { "id" : "P2", "parent" : "C2", "text" : "Project 2" },
  #   ]
  # } });
  
  
  user_collections <- function (user_id) {
    
    #________________________________________________________
    # All the COLLECTIONS for this user.
    #________________________________________________________
    sql <- "SELECT * FROM collections WHERE user_id = ?"
    res <- db_query(DB, sql, "AJData1", user_id, simplify = FALSE)
    
    collections <- lapply(seq_len(nrow(res)), function (i) {
      jstree_node <- compile_jstree_node(DB, as.list(res[i,]))
      return (jstree_node)
    })
    
    
    #________________________________________________________
    # All the PROJECTS for this user.
    #________________________________________________________
    sql <- paste0(
      "SELECT * FROM permissions",
      " LEFT JOIN projects    USING (project_id)",
      " LEFT JOIN last_access USING (user_id, project_id)",
      " WHERE user_id = ?" )
    res <- db_query(DB, sql, "AJData2", user_id, simplify = FALSE)
    
    projects <- lapply(seq_len(nrow(res)), function (i) {
      jstree_node <- compile_jstree_node(DB, as.list(res[i,]))
      return (jstree_node)
    })
    
    
    return (c(collections, projects))
  }
  
  
  #________________________________________________________
  # Return both the PUBLIC and PRIVATE collections.
  #________________________________________________________
  
  resp <- list(
    public  = user_collections(0L),
    private = user_collections(user_id) )
  
  
  
  return (resp)
}



#______________________________________________________________________________
#' Add a new folder to the jsTree via the jsTree context menu.
#' @return list(parent_id, node = list(id, text, children))
api_jstree_create <- function (REQ, node_id) {
  
  sanity_check(node_id)
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  
  #________________________________________________________
  # If this will be a subfolder, 
  # find the ID for the parent folder.
  #________________________________________________________
  parent_collection_id <- local({
    
    if (startsWith(node_id, 'P')) {
      
      permission_id <- int(substr(node_id, 2, nchar(node_id)))
      
      sql <- "SELECT collection_id FROM permissions WHERE permission_id = ? AND user_id = ?"
      collection_id <- db_query(DB, sql, "AJCrea1", list(permission_id, user_id))
      
      if (length(collection_id) == 0)
        stop(error_details("Zero collections found.", SQL = sql))
      
      return (if.na(collection_id, NULL))
      
    } else if (startsWith(node_id, 'C')) {
      return (int(substr(node_id, 2, nchar(node_id))))
      
    } else {
      return (NULL)
    }
    
  })
  
  
  #________________________________________________________
  # Add the new collection to the database.
  #________________________________________________________
  new_collection_id <- create_collection(
    DB                   = DB, 
    user_id              = user_id, 
    parent_collection_id = parent_collection_id, 
    jstree_text          = "New Collection" )
  
  
  res <- list(
    
    parent_id = ifelse(
      test = is.null(parent_collection_id), 
      yes  = unbox("#"), 
      no   = unbox(paste0("C", parent_collection_id))),
    
    node = list(
      id       = unbox(paste0("C", new_collection_id)), 
      text     = unbox("New Collection"),
      children = list() ))
  
  return (res)
}



#______________________________________________________________________________
#' Rename a project or collection via the jsTree context menu.
#' @return list()
api_jstree_rename <- function (REQ, node_id, jstree_text) {
  
  DB         <- REQ[['DB']]
  user_id    <- REQ[['SESSION']][['user_id']]
  project_id <- REQ[['SESSION']][['project_id']]
  
  sanity_check(node_id)
  
  
  
  #________________________________________________________
  # Renaming a PROJECT, based on permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {
    
    permission_id <- int(substr(node_id, 2, nchar(node_id)))
    
    sql <- paste0(
      "SELECT project_id FROM permissions",
      " WHERE permission_id = ? AND user_id = ? AND is_editor = 1" )
    params <- list(permission_id, user_id)
    pid    <- db_query(DB, sql, "AJRena1", params)
    
    if (is.null(pid))
      stop("You do not have permission to rename this project.")
    
    
    # Update the draft's title too.
    if (identical(pid, project_id)) {
      resp <- api_update_title(REQ, title = jstree_text)
      return (list('title' = unbox(resp[['title']])))
    }
  }
  
  
  
  #________________________________________________________
  # Renaming a COLLECTION, based on collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {
    
    collection_id <- int(substr(node_id, 2, nchar(node_id)))
    
    sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id = ?"
    if (db_query(DB, sql, "AJRena2", list(collection_id, user_id)) == 0)
      stop("You do not have permission to rename this collection.")
    
    sql <- "UPDATE collections SET jstree_text = ? WHERE collection_id = ?"
    db_query(DB, sql, "AJRena3", list(substr(jstree_text, 1, 100), collection_id))
  }
  
  
  return (list())
}



#______________________________________________________________________________
#' Leave a project via the jsTree context menu. Delete our permissions to it.
#' @return list()
api_jstree_leave <- function (REQ, node_id) {
  
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  sanity_check(node_id)
  stopifnot(startsWith(node_id, 'P'))
  
  permission_id <- int(substr(node_id, 2, nchar(node_id)))
  
  
  #________________________________________________________
  # Lookup project, verify the user isn't sole editor.
  #________________________________________________________
  sql <- "SELECT project_id FROM permissions WHERE permission_id = ? AND user_id = ?"
  project_id <- db_query(DB, sql, "AJLeav1", list(permission_id, user_id))
  if (is.null(project_id))
    stop(error_details("That project does not exist.", SQL = sql))
  
  sql <- "DELETE FROM permissions WHERE permission_id = ? AND user_id = ?"
  db_query(DB, sql, "AJLeav2", list(permission_id, user_id))
  
  return (list())
}



#______________________________________________________________________________
#' Delete a project or empty collection via the jsTree context menu.
#' @return list(node_id)
api_jstree_delete <- function (REQ, node_id) {
  
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  sanity_check(node_id)
  
  
  # Deleting a PROJECT, based on a permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {
    
    permission_id <- int(substr(node_id, 2, nchar(node_id)))
    
    # Convert permission_id to project_id (include user_id to prevent hackery)
    sql <- paste0(
      "SELECT project_id FROM permissions",
      " WHERE permission_id = ? AND user_id = ? AND is_editor = 1" )
    project_id <- db_query(DB, sql, "AJDel1", list(permission_id, user_id))
    
    if (is.null(project_id))
      stop(error_details("That project does not exist.", SQL = sql))
    
    
    # Really, just delete all permissions to it, to avoid clobbering 
    # other users' open drafts (where draft_id == this project_id).
    # The garbage collector cronjob will eventually remove all such
    # orphaned projects and objects.
    sql <- "DELETE FROM permissions WHERE project_id = ?"
    db_query(DB, sql, "AJDel2", list(project_id))
  }
  
  
  
  # Deleting an empty COLLECTION, based on a collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {
    
    collection_id <- int(substr(node_id, 2, nchar(node_id)))
    
    # Does this collection exist?
    sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ?"
    if (db_query(DB, sql, "AJDel3", list(collection_id)) == 0)
      stop("This collection does not exist. Please reload the page.")
    
    # Does this collection belong to this user?
    sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id = ?"
    if (db_query(DB, sql, "AJDel4", list(collection_id, user_id)) == 0)
      stop(error_details("You do not have permission to delete this collection.", SQL = sql))
    
    # Are there sub-collections that need to be removed first?
    sql <- "SELECT COUNT(*) FROM collections WHERE parent_collection_id = ?"
    if (db_query(DB, sql, "AJDel5", list(collection_id)) > 0)
      stop("Unable to delete non-empty collections.")
    
    # Are there projects in this collection that need to be removed first?
    sql <- "SELECT COUNT(*) FROM permissions WHERE collection_id = ?"
    if (db_query(DB, collection_id, "AJDel6", list(collection_id)) > 0)
      stop("Unable to delete non-empty collections.")
    
    sql <- "DELETE FROM collections WHERE collection_id = ?"
    db_query(DB, sql, "AJDel7", list(collection_id))
  }
  
  
  return (list())
}



#______________________________________________________________________________
#' Move a node in the jsTree via drag and drop.
#' @return list()
api_jstree_move <- function (REQ, node_id, parent_node_id) {
  
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  sanity_check(node_id, parent_node_id)
  
  
  # Verify that this user owns the new parent collection.
  #________________________________________________________
  parent_collection_id <- int(substr(parent_node_id, 2, nchar(parent_node_id)))
  
  sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id = ?"
  if (db_query(DB, sql, "AJMove1", list(parent_collection_id, user_id)) == 0)
    stop(error_details("You do not have permission to move to this collection.", SQL = sql))
  
  
  
  # Moving a PROJECT, based on permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {
    
    permission_id <- int(substr(node_id, 2, nchar(node_id)))
    
    sql <- "SELECT COUNT(*) FROM permissions WHERE permission_id = ? AND user_id = ?"
    if (db_query(DB, sql, "AJMove2", list(permission_id, user_id)) == 0)
      stop(error_details("You do not have permission to move this project.", SQL = sql))
    
    sql <- "UPDATE permissions SET collection_id = ? WHERE permission_id = ?"
    db_query(DB, sql, "AJMove3", list(parent_collection_id, permission_id))
  }
  
  
  
  # Moving a COLLECTION, based on collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {
    
    collection_id <- int(substr(node_id, 2, nchar(node_id)))
    
    sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id = ?"
    if (db_query(DB, sql, "AJMove4", list(collection_id, user_id)) == 0)
      stop(error_details("You do not have permission to rename this collection.", SQL = sql))
    
    sql <- "UPDATE collections SET parent_collection_id = ? WHERE collection_id = ?"
    db_query(DB, sql, "AJMove5", list(parent_collection_id, collection_id))
  }
  
  
  return (list())
}


#______________________________________________________________________________
#' Create a new collection.
#' When user_id = NULL, it's public.
#' When parent_collection_id = NULL, it's a top level directory.
#' @return a collection_id.
create_collection <- function (DB, user_id, parent_collection_id, jstree_text) {
  
  sanity_check(user_id, parent_collection_id, jstree_text)
  
  # Check that the same user owns the parent collection
  #________________________________________________________
  if (!is.null(parent_collection_id)) {
    sql        <- "SELECT user_id FROM collections WHERE collection_id = ?"
    pc_user_id <- db_query(DB, sql, "CColl1", list(parent_collection_id))
    
    if (!((is.null(user_id) && is.na(pc_user_id)) || identical(pc_user_id, user_id))) {
      errmsg <- "user_id %i does not own parent_collection_id %i"
      errmsg <- sprintf(sql, user_id, parent_collection_id)
      stop(error_details(errmsg, "CColl2"))
    }
  }
  
  
  collection_id <- db_insert(
    DB                   = DB,
    table                = "collections", 
    err_code             = "CColl3",
    user_id              = user_id,
    parent_collection_id = parent_collection_id,
    jstree_text          = trimws(jstree_text) )
  
  return (collection_id)
}


#______________________________________________________________________________
#' Format an SQL result row for use by jstree.
#' @return node
compile_jstree_node <- function (DB, row) {
  
  if (hasName(row, 'project_id')) {
    
    parent_node_id <- ifelse(
      test = is.na(row[['collection_id']]), 
      yes  = "#", 
      no   = paste0("C", row[['collection_id']]) )
    
    res <- list(
      id     = unbox(paste0("P", row[['permission_id']])),
      parent = unbox(parent_node_id),
      text   = unbox(row[['title']]),
      editor = unbox(row[['is_editor']] && row[['user_id']] > 0),
      icon   = unbox(if.blank(row[['jstree_icon']], 'fa fa-file')),
      info   = list(
        
        access_key   = unbox(row[['access_key']]),
        created_utc  = unbox(row[['created_utc']]),
        has_tree     = unbox(row[['has_tree']]),
        median_depth = unbox(row[['median_depth']]),
        n_samples    = unbox(row[['n_samples']]),
        n_taxa       = unbox(row[['n_taxa']]),
        viewed_utc   = unbox(row[['viewed_utc']]),
        description  = unbox(row[['description']]),
        
        # `editors` and `meta_colnames` are arrays encoded as JSON in SQL TEXT columns.
        editors       = fromJSON(row[['editors']]),
        meta_colnames = fromJSON(row[['meta_colnames']])
    ))
    
    
    return (res)
    
    
  } else {
    
    res <- list(
      id     = unbox(paste0("C", row[['collection_id']])),
      parent = unbox("#"),
      text   = unbox(row[['jstree_text']]) )
    
    if (!is.na(row[['parent_collection_id']]))
      res[['parent']] <- unbox(paste0("C", row[['parent_collection_id']]))
    
    if (nzchar(row[['jstree_icon']]))
      res[['icon']] <- unbox(row[['jstree_icon']])
    
    return (res)
    
  }
  
}






#______________________________________________________________________________
#' Find / Create a collection_id for sharing
#' projects from grantor_user_id to user_id.
#' @return collection_id or NULL
get_shared_collection <- function (DB, user_id, grantor_user_id, create = TRUE) {
  
  # Use the user's top-level collection.
  if (is.null(grantor_user_id))
    return (NULL)
    
  
  sql         <- "SELECT full_name, email FROM users WHERE user_id = ?"
  grantor     <- db_query(DB, sql, "GSColl1", list(grantor_user_id))
  jstree_text <- with(grantor, sprintf("Shared by %s (%s)", full_name, email))
  
  sql <- paste0(
    "SELECT collection_id FROM collections",
    " WHERE jstree_text = ? AND user_id = ?" )
  params        <- list(jstree_text, user_id)
  collection_id <- db_query(DB, sql, "GSColl2", params)
  
  if (isTRUE(create) && is.null(collection_id))
    collection_id <- create_collection(DB, user_id, parent_collection_id = NULL, jstree_text)
  
  return (collection_id)
}




#______________________________________________________________________________
#' Delete the shared collection if it's empty.
#' 
cleanup_shared_collection <- function (DB, user_id, grantor_user_id) {
  
  collection_id <- get_shared_collection(DB, user_id, grantor_user_id, create = FALSE)
  
  if (is.null(collection_id)) return (NULL)
    
  sql <- "SELECT COUNT(*) FROM permissions WHERE collection_id = ?"
  res <- db_query(DB, sql, "CSColl1", list(collection_id))
  if (!identical(res, 0L)) return (NULL)
  
  sql <- "SELECT COUNT(*) FROM collections WHERE parent_collection_id = ?"
  res <- db_query(DB, sql, "CSColl2", list(collection_id))
  if (!identical(res, 0L)) return (NULL)
  
  sql <- "DELETE FROM collections WHERE collection_id = ? AND parent_collection_id IS NOT NULL"
  db_query(DB, sql, "CSColl3", list(collection_id))
  
  return (NULL)
}








