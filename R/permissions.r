
#______________________________________________________________________________
#' Find users matching a user-entered query string.
#' For a server-side selectize drop-down.
#' @return list(users = list(user_id, full_name, affiliation, email))
api_sharing_user_search <- function (REQ, query) {
  
  DB <- REQ[['DB']]
  
  # Sanity check the query string.
  stopifnot(is_scalar_character(query))
  stopifnot(nchar(query) > 0 && nchar(query) < 100)
  stopifnot(grepl("^[A-Za-z0-9@_ \\.\\-]+$", query))
  
  
  # Pull all the users from the database table.
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, email", 
    " FROM users WHERE is_guest = 0 AND user_id > 0" )
  res <- db_query(DB, sql, "ASUS1")
  
  
  # Fuzzy matching using Levenshtein string distance.
  strings <- paste(res[['full_name']], res[['affiliation']], res[['email']])
  dists   <- adist(x = query, y = strings, partial = TRUE, ignore.case = TRUE)
  
  
  # Only keep the 6 best matches.
  res <- res[head(order(dists)),,drop=FALSE]
  
  
  # Redact the email address a little.
  res[['email']] <- redact_emails(res[['email']])
    
  
  return (list(users = res))
}



#______________________________________________________________________________
#' Fetch the list of current editors for the active project.
#' @return list(users = list(user_id, full_name, affiliation, email))
api_get_editors <- function (REQ) {
  
  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]
  
  # Find users who are editors on this project.
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, email", 
    " FROM permissions",
    "   LEFT JOIN users USING (user_id)", 
    " WHERE project_id = ? AND is_editor = 1" )
  res <- db_query(DB, sql, "AGEdit1", list(project_id))
  
  # Redact email addresses a little.
  res[['email']] <- redact_emails(res[['email']])
  
  return (list(users = res))
}




#______________________________________________________________________________
#' Look up who has read-only and/or editor access to this project.
#' @return list(dt_data = list(c(user_id, full_name, affiliation, is_editor), ...))
api_sharing_with <- function (REQ) {
  
  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]
  
  
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, is_editor",
    " FROM permissions", 
    "   LEFT JOIN users USING (user_id)",
    " WHERE project_id = ? AND is_guest = 0" )
  res <- db_query(DB, sql, "ASWith1", list(project_id), simplify = FALSE)
  
  public <- any(res[['user_id']] == 0)
  if (public)
    res <- res[res[['is_editor']],,drop=FALSE]
  
  return (list(dt_data = as.matrix(res)))
}



#______________________________________________________________________________
#' Allow a user to modify another user's project permissions.
#' @return list()
api_update_permissions <- function (REQ, user_id, permissions) {
  
  DB              <- REQ[['DB']]
  project_id      <- REQ[['SESSION']][['project_id']]
  grantor_user_id <- REQ[['SESSION']][['user_id']]
  
  
  #________________________________________________________
  # Verify grantor permissions.
  #________________________________________________________
  can_grant(
    DB              = DB, 
    user_id         = user_id, 
    grantor_user_id = grantor_user_id, 
    project_id      = project_id, 
    permissions     = permissions, 
    assert          = TRUE )
  
  
  update_permissions(
    DB              = DB, 
    user_id         = user_id, 
    project_id      = project_id, 
    permissions     = permissions,
    grantor_user_id = grantor_user_id )
  
  
  return (list())
}



#______________________________________________________________________________
#' Modify a user's access to a project.
#' @return permission_id
update_permissions <- function (DB, user_id, project_id, permissions, grantor_user_id = NULL) {
  
  stopifnot(isTRUE(user_id > 0L)) # Use make_public() instead.
  stopifnot(is_one_of(permissions, c("none", "view", "edit", "any")))
  
  
  #________________________________________________________
  # Look up this permission entry (if it exists yet).
  #________________________________________________________
  sql <- "SELECT * FROM permissions WHERE user_id = ? AND project_id = ?"
  row <- db_query(DB, sql, "UPerm1", list(user_id, project_id))
  
  permission_id <- row[['permission_id']]
  
  
  if (identical(permissions, "none")) { # Revoke
    
    if (is.null(permission_id))
      stop("No permission entry found.")
    
    sql <- "DELETE FROM permissions WHERE permission_id = ?"
    db_query(DB, sql, "UPerm2", list(permission_id))
    
    permission_id <- NULL
    
    
  } else if (is.null(row)) { # Grant
    
    permission_id <- db_insert(
      DB              = DB, 
      table           = "permissions", 
      err_code        = "UPerm3", 
      user_id         = user_id, 
      project_id      = project_id, 
      collection_id   = get_shared_collection(DB, user_id, grantor_user_id), 
      is_editor       = (permissions == "edit"), 
      grantor_user_id = grantor_user_id )
    
    
  } else if (permissions != "any") { # Modify
    
    db_update(
      DB              = DB, 
      table           = "permissions", 
      id              = permission_id, 
      err_code        = "UPerm4", 
      collection_id   = get_shared_collection(DB, user_id, grantor_user_id), 
      is_editor       = (permissions == "edit"), 
      grantor_user_id = grantor_user_id )
    
  }
  
  
  if (!is.null(row) && !is.na(row[['grantor_user_id']]))
    cleanup_shared_collection(DB, user_id, row[['grantor_user_id']])
  
  
  return (permission_id)
}




#______________________________________________________________________________
#' Check if a user is allowed to alter another user's project permissions.
#' @return redacted_email
can_grant <- function (DB, user_id, grantor_user_id, project_id, permissions, assert = FALSE) {
  
  stopifnot(is_scalar_integer(user_id))
  stopifnot(is_scalar_integer(grantor_user_id))
  stopifnot(is_scalar_integer(project_id))
  stopifnot(is_one_of(permissions, c("none", "view", "edit", "any")))
  stopifnot(is_bool(assert))
  
  
  
  #________________________________________________________
  # Don't allow grants to or from guests.
  #________________________________________________________
  
  sql <- "SELECT is_guest FROM users WHERE user_id = ?"
  
  if (db_query(DB, sql, "VGran1", list(user_id), req1 = TRUE)) {
    if (assert) stop("Cannot grant permissions to a guest account.")
    return (FALSE)
  }
  
  if (db_query(DB, sql, "VGran2", list(grantor_user_id), req1 = TRUE)) {
    if (assert) stop("Cannot grant permissions from a guest account.")
    return (FALSE)
  }
  
  
  
  #________________________________________________________
  # Don't give users view access to public projects.
  #________________________________________________________
  
  if (permissions %in% c("view", "any")) {
    
    sql <- paste0(
      "SELECT permission_id FROM permissions",
      " WHERE user_id = 0 AND project_id = ?" )
    if (!is.null(db_query(DB, sql, "VGran3", list(project_id)))) {
      if (assert) stop("Public projects are already viewable by everyone.")
      return (FALSE)
    }
  }
  
  
  
  #________________________________________________________
  # Check grantor's permission level.
  #________________________________________________________
  
  sql <- "SELECT is_editor FROM permissions WHERE user_id = ? and project_id = ?"
  gperm <- db_query(DB, sql, "VGran4", list(grantor_user_id, project_id))
  gperm <- ifelse(is.null(gperm), "none", ifelse(gperm, "edit", "view"))
  
  if (gperm == "edit")
    return (TRUE)
  
  if (gperm == "none") {
    if (assert) stop("You do not have granting permissions.")
    return (FALSE)
  }
  
  if (permissions == "edit") {
    if (assert) stop("Insufficient rights to grant editor permissions.")
    return (FALSE)
  }
  
  stopifnot(identical(gperm, "view"))
  stopifnot(is_one_of(permissions, c("none", "view", "any")))
  
  
  
  #________________________________________________________
  # User's current permission level.
  #________________________________________________________
  
  sql <- "SELECT is_editor FROM permissions WHERE user_id = ? and project_id = ?"
  uperm <- db_query(DB, sql, "VGran5", list(user_id, project_id))
  uperm <- ifelse(is.null(uperm), "none", ifelse(uperm, "edit", "view"))
  
  if (uperm == "none") return (TRUE)
  
  if (uperm == "edit") {
    if (assert) stop("Insufficient rights to modify an editor's permissions.")
    return (FALSE)
  }
  
  stopifnot(identical(uperm, "view"))
  
  
  
  #________________________________________________________
  # Both user and grantor have 'view' permissions.
  #________________________________________________________
  
  if (permissions %in% c("view", "any")) {
    if (assert) stop("User already has view permissions.")
    return (FALSE)
  }
  
  stopifnot(identical(permissions, "none"))
  
  
  
  #________________________________________________________
  # One viewer is trying to remove another viewer's rights.
  #________________________________________________________
  
  sql <- paste0(
    "SELECT grantor_user_id FROM permissions",
    " WHERE user_id = ? AND project_id = ?" )
  res <- db_query(DB, sql, "VGran6", list(user_id, project_id))
  
  if (identical(res, grantor_user_id)) {
    return (TRUE)
    
  } else {
    if (assert) stop("Action not allowed.")
    return (FALSE)
  }
  
}




#______________________________________________________________________________
#' Partially redact the username of email addresses with asterisks.
#' @return redacted_email
redact_emails <- function (emails) {
  sapply(emails, function (email) {
  
    x <- strsplit(email, '@', fixed = TRUE)[[1]]
    if (length(x) != 2) return (email)
    
    len <- nchar(x[[1]])
    if (len <= 3)        { i <- 1; j <- 0;
    } else if (len <= 5) { i <- 1; j <- 1;
    } else if (len <= 8) { i <- 2; j <- 1;
    } else               { i <- 2; j <- 2; }
    
    sprintf(
      fmt = "%s%s%s@%s",
      substr(x[[1]], 1, i),
      paste(collapse = '', rep('*', len - i - j)),
      ifelse(j == 0, "", substr(x[[1]], len - j + 1, len)),
      x[[2]] )
  })
}

