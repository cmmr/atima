
#______________________________________________________________________________
# The project tree.
#
# Node ids are a letter and a number:
#   C<collection_id>  a collection (folder), private or public
#   P<permission_id>  a project in the user's own tree
#   G<project_id>     a project in the public tree
# "#" is the top of a tree.
#
# The router checks the format of node ids and, through the `tree` and
# `tree_edit` rules in `R/access.R`, that the nodes belong to the caller.
#
# The public tree is arranged by administrators through routes of its own
# (`/api/public/*`, the `api_public_*()` handlers below). For those the
# router checks that the caller is an administrator and, through the
# `public_tree` rule, that the nodes are public ones.
#______________________________________________________________________________


#' The number part of a node id.
#' @noRd
node_number <- function (node_id) {
  as.integer(substr(node_id, 2, nchar(node_id)))
}


#______________________________________________________________________________
#' The `permissions` row behind a project node (`P<permission_id>`) of the
#' caller's tree. The router has already checked that it is theirs.
#' @return The row as a list.
#' @noRd
node_permission <- function (DB, node_id) {
  sql <- "SELECT * FROM permissions WHERE permission_id = ?"
  db_query(DB, sql, "NPerm1", list(node_number(node_id)), req1 = TRUE)
}


#______________________________________________________________________________
#' Open the project that the user selected.
#' @return list(BIOM)
#' @noRd
api_tree_select <- function (REQ, node_id) {

  DB      <- REQ[['DB']]

  project_id <-
    if (startsWith(node_id, "P")) { node_permission(DB, node_id)[['project_id']]
    } else                        { node_number(node_id) }

  select_project(REQ, project_id = project_id)

  with_biom_data(REQ, function (BIOM) list(BIOM = BIOM))
}



#______________________________________________________________________________
#' Generate the tree data for the public and private project trees.
#'
#' @return list(public, private), each an array of node definitions, already
#'         unboxed.
#' @noRd
tree_data <- function (REQ) {

  DB       <- REQ[['DB']]
  user_id  <- REQ[['SESSION']][['user_id']]
  is_admin <- isTRUE(REQ[['SESSION']][['is_admin']])

  nodes <- function (sql, err_code, params = NULL, ...) {
    res <- db_query(DB, sql, err_code, params, simplify = FALSE)
    lapply(seq_len(nrow(res)), function (i) tree_node(as.list(res[i,]), ...))
  }


  #________________________________________________________
  # PUBLIC: collections that belong to nobody, and every
  # project marked as public.
  #________________________________________________________
  public <- c(
    nodes("SELECT * FROM collections WHERE user_id IS NULL", "AJData1"),
    nodes("SELECT * FROM projects WHERE public_key IS NOT NULL", "AJData2", public = TRUE, editor = is_admin) )


  #________________________________________________________
  # PRIVATE: this user's collections, and the projects
  # they have been granted.
  #________________________________________________________
  sql <- paste0(
    "SELECT * FROM permissions",
    " LEFT JOIN projects    USING (project_id)",
    " LEFT JOIN last_access USING (user_id, project_id)",
    " WHERE user_id = ?" )

  private <- c(
    nodes("SELECT * FROM collections WHERE user_id = ?", "AJData3", list(user_id)),
    nodes(sql, "AJData4", list(user_id)) )


  return (list(public = public, private = private))
}




#______________________________________________________________________________
#' Add a new folder to the user's tree.
#' @return list(parent_id, node = list(id, text, children))
#' @noRd
api_tree_create <- function (REQ, node_id) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  
  #________________________________________________________
  # If this will be a subfolder, 
  # find the ID for the parent folder.
  #________________________________________________________
  parent_collection_id <- local({
    
    if (startsWith(node_id, 'P')) {
      return (if.na(node_permission(DB, node_id)[['collection_id']], NULL))

    } else if (startsWith(node_id, 'C')) {
      return (node_number(node_id))

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
#' Rename a project or collection.
#' @return list(), or list(title) when the open project was renamed.
#' @noRd
api_tree_rename <- function (REQ, node_id, text) {

  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]


  #________________________________________________________
  # Renaming a PROJECT, based on permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {

    pid <- node_permission(DB, node_id)[['project_id']]
    db_update(DB, "projects", pid, "AJRena1", title = text)

    # Tell the client when it was the open project that got renamed.
    if (identical(pid, project_id))
      return (list('title' = unbox(text)))
  }


  #________________________________________________________
  # Renaming a COLLECTION, based on collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {
    db_update(DB, "collections", node_number(node_id), "AJRena2", jstree_text = text)
  }


  return (list())
}



#______________________________________________________________________________
#' Leave a project. Delete our permissions to it.
#' @return list()
#' @noRd
api_tree_leave <- function (REQ, node_id) {

  DB      <- REQ[['DB']]

  sql <- "DELETE FROM permissions WHERE permission_id = ?"
  db_query(DB, sql, "AJLeav1", list(node_number(node_id)))

  return (list())
}



#______________________________________________________________________________
#' Delete a project or empty collection.
#' @return list()
#' @noRd
api_tree_delete <- function (REQ, node_id) {

  DB      <- REQ[['DB']]


  # Deleting a PROJECT, based on a permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {

    project_id <- node_permission(DB, node_id)[['project_id']]

    # Really, just delete all permissions to it, to avoid clobbering
    # other users' open drafts of this project. Projects that nobody
    # can reach any more are removed by the cleanup job.
    sql <- "DELETE FROM permissions WHERE project_id = ?"
    db_query(DB, sql, "AJDel1", list(project_id))
  }


  # Deleting an empty COLLECTION, based on a collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {

    collection_id <- node_number(node_id)

    # Are there sub-collections that need to be removed first?
    sql <- "SELECT COUNT(*) FROM collections WHERE parent_collection_id = ?"
    if (db_query(DB, sql, "AJDel2", list(collection_id)) > 0)
      stop_user("Unable to delete non-empty collections.")

    # Are there projects in this collection that need to be removed first?
    sql <- "SELECT COUNT(*) FROM permissions WHERE collection_id = ?"
    if (db_query(DB, sql, "AJDel3", list(collection_id)) > 0)
      stop_user("Unable to delete non-empty collections.")

    sql <- "DELETE FROM collections WHERE collection_id = ?"
    db_query(DB, sql, "AJDel4", list(collection_id))
  }


  return (list())
}



#______________________________________________________________________________
#' Move a node in the tree.
#' @param parent_node_id  The collection to move into, or "#" for the top
#'        of the user's tree.
#' @return list()
#' @noRd
api_tree_move <- function (REQ, node_id, parent_node_id) {

  DB      <- REQ[['DB']]

  parent_collection_id <-
    if (identical(parent_node_id, "#")) { NULL
    } else                              { node_number(parent_node_id) }


  # Moving a PROJECT, based on permission_id
  #________________________________________________________
  if (startsWith(node_id, 'P')) {
    db_update(DB, "permissions", node_number(node_id), "AJMove1", collection_id = parent_collection_id)
  }


  # Moving a COLLECTION, based on collection_id
  #________________________________________________________
  if (startsWith(node_id, 'C')) {

    collection_id <- node_number(node_id)

    check_collection_parent(DB, collection_id, parent_collection_id)

    db_update(DB, "collections", collection_id, "AJMove3", parent_collection_id = parent_collection_id)
  }


  return (list())
}



#______________________________________________________________________________
#' Stop if a collection is to be moved inside itself or one of its own
#' descendants.
#' @param parent_collection_id  Where it is to go; `NULL` for the top level.
#' @noRd
check_collection_parent <- function (DB, collection_id, parent_collection_id) {

  ancestor <- parent_collection_id

  while (!is.null(ancestor)) {
    if (identical(ancestor, collection_id))
      stop_user("A collection cannot be moved inside itself.")
    sql      <- "SELECT parent_collection_id FROM collections WHERE collection_id = ?"
    ancestor <- if.na(db_query(DB, sql, "AJMove2", list(ancestor)), NULL)
  }

  invisible(TRUE)
}



#______________________________________________________________________________
# The public tree. These four are for administrators. The router has checked
# that, and that every node named is a public collection or a public project.
#______________________________________________________________________________


#' The collection a parent node stands for: `NULL` for `"#"`, the top level.
#' @noRd
parent_collection <- function (parent_node_id) {
  if (identical(parent_node_id, "#")) NULL else node_number(parent_node_id)
}


#______________________________________________________________________________
#' Add a collection to the public tree.
#' @param parent_node_id  The public collection to put it in, or "#" for the
#'        top of the public tree.
#' @param text  Its name.
#' @return list(node = list(id, parent, text))
#' @noRd
api_public_create <- function (REQ, parent_node_id, text) {

  collection_id <- create_collection(
    DB                   = REQ[['DB']],
    user_id              = NULL,
    parent_collection_id = parent_collection(parent_node_id),
    jstree_text          = text )

  list(node = list(
    id     = unbox(paste0("C", collection_id)),
    parent = unbox(parent_node_id),
    text   = unbox(text) ))
}


#______________________________________________________________________________
#' Rename a public collection.
#' @return list()
#' @noRd
api_public_rename <- function (REQ, node_id, text) {
  db_update(REQ[['DB']], "collections", node_number(node_id), "APRena1", jstree_text = text)
  return (list())
}


#______________________________________________________________________________
#' Delete an empty public collection.
#'
#' As with a user's own collections, one that still holds something is
#' refused: the administrator moves its projects and collections elsewhere
#' first. So deleting a collection never changes where a public project is
#' listed, and never unpublishes one.
#' @return list()
#' @noRd
api_public_delete <- function (REQ, node_id) {

  DB            <- REQ[['DB']]
  collection_id <- node_number(node_id)

  sql <- "SELECT COUNT(*) FROM collections WHERE parent_collection_id = ?"
  if (db_query(DB, sql, "APDel1", list(collection_id)) > 0)
    stop_user("Unable to delete non-empty collections.")

  sql <- "SELECT COUNT(*) FROM projects WHERE public_collection_id = ? AND public_key IS NOT NULL"
  if (db_query(DB, sql, "APDel2", list(collection_id)) > 0)
    stop_user("Unable to delete non-empty collections.")

  sql <- "DELETE FROM collections WHERE collection_id = ?"
  db_query(DB, sql, "APDel3", list(collection_id))

  return (list())
}


#______________________________________________________________________________
#' Move a public collection, or a public project, within the public tree.
#' @param parent_node_id  The public collection to move into, or "#" for the
#'        top of the public tree.
#' @return list()
#' @noRd
api_public_move <- function (REQ, node_id, parent_node_id) {

  DB                   <- REQ[['DB']]
  parent_collection_id <- parent_collection(parent_node_id)

  if (startsWith(node_id, 'G')) {
    db_update(DB, "projects", node_number(node_id), "APMove1", public_collection_id = parent_collection_id)
  }

  if (startsWith(node_id, 'C')) {
    collection_id <- node_number(node_id)
    check_collection_parent(DB, collection_id, parent_collection_id)
    db_update(DB, "collections", collection_id, "APMove2", parent_collection_id = parent_collection_id)
  }

  return (list())
}



#______________________________________________________________________________
#' Create a new collection.
#' When user_id = NULL, it's public.
#' When parent_collection_id = NULL, it's a top level directory.
#' @return a collection_id.
#' @noRd
create_collection <- function (DB, user_id, parent_collection_id, jstree_text) {
  
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
#'
#' @param row     A row of `collections`, or of `projects` (joined to
#'                `permissions` for a node in a user's own tree).
#' @param public  Is this a project node for the public tree?
#' @param editor  For a public project node: may the caller change it?
#' @return node
#' @noRd
tree_node <- function (row, public = FALSE, editor = FALSE) {

  if (hasName(row, 'project_id')) {

    collection_id <- row[[ifelse(public, 'public_collection_id', 'collection_id')]]

    parent_node_id <- ifelse(
      test = is.na(collection_id),
      yes  = "#",
      no   = paste0("C", collection_id) )

    node_id <- ifelse(
      test = public,
      yes  = paste0("G", row[['project_id']]),
      no   = paste0("P", row[['permission_id']]) )

    res <- list(
      id     = unbox(node_id),
      parent = unbox(parent_node_id),
      text   = unbox(row[['title']]),
      editor = unbox(ifelse(public, editor, isTRUE(row[['is_editor']]))),
      icon   = unbox(if.blank(row[['jstree_icon']], 'fa fa-file')),
      info   = list(
        
        # In the public tree a project goes by its public key. Its private
        # key is only for those who have it in their own tree.
        access_key   = unbox(row[[ifelse(public, 'public_key', 'access_key')]]),
        created_utc  = unbox(row[['created_utc']]),
        has_tree     = unbox(row[['has_tree']]),
        median_depth = unbox(row[['median_depth']]),
        n_samples    = unbox(row[['n_samples']]),
        n_taxa       = unbox(row[['n_taxa']]),
        viewed_utc   = unbox(row[['viewed_utc']] %||% NA),
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
#' @noRd
get_shared_collection <- function (DB, user_id, grantor_user_id, create = TRUE) {
  
  # Use the user's top-level collection.
  if (is.null(grantor_user_id))
    return (NULL)
    
  
  sql         <- "SELECT full_name FROM users WHERE user_id = ?"
  jstree_text <- paste("Shared by", db_query(DB, sql, "GSColl1", list(grantor_user_id)))
  
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
#' @noRd
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








