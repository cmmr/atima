
#______________________________________________________________________________
# Sharing the open project with other users.
#
# What other users are shown about a person is their name, their
# affiliation and a partly hidden email address (`redact_emails()`). Someone
# who signed in through a provider that gives no email (ORCID) has none.
#
# Who may change whose grant is decided by the router, with the `grant`
# rule in `R/access.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Find users matching a user-entered query string.
#' For a server-side selectize drop-down.
#' @return list(users = list(user_id, full_name, affiliation, email))
#' @noRd
api_sharing_user_search <- function (REQ, query) {
  
  DB <- REQ[['DB']]

  # Pull all the users from the database table.
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, email",
    " FROM users WHERE is_guest = 0" )
  res <- db_query(DB, sql, "ASUS1", simplify = FALSE)
  
  
  # Fuzzy matching using Levenshtein string distance.
  blank   <- function (x) ifelse(is.na(x), "", x)
  strings <- paste(res[['full_name']], blank(res[['affiliation']]), blank(res[['email']]))
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
#' @noRd
api_get_editors <- function (REQ) {
  
  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]
  
  # Find users who are editors on this project.
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, email", 
    " FROM permissions",
    "   LEFT JOIN users USING (user_id)", 
    " WHERE project_id = ? AND is_editor = 1" )
  res <- db_query(DB, sql, "AGEdit1", list(project_id), simplify = FALSE)
  
  # Redact email addresses a little.
  res[['email']] <- redact_emails(res[['email']])
  
  return (list(users = res))
}




#______________________________________________________________________________
#' Look up who has read-only and/or editor access to this project.
#' @return list(dt_data = list(c(user_id, full_name, affiliation, is_editor), ...))
#' @noRd
api_sharing_with <- function (REQ) {
  
  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]
  
  
  sql <- paste0(
    "SELECT user_id, full_name, affiliation, is_editor",
    " FROM permissions", 
    "   LEFT JOIN users USING (user_id)",
    " WHERE project_id = ? AND is_guest = 0" )
  res <- db_query(DB, sql, "ASWith1", list(project_id), simplify = FALSE)

  # Everyone can already view a public project, so only list its editors.
  if (REQ[['SESSION']][['is_public']])
    res <- res[res[['is_editor']],,drop=FALSE]
  
  return (list(dt_data = as.matrix(res)))
}



#______________________________________________________________________________
#' Change another user's grant on the open project. The router has already
#' checked that the caller may make this change.
#' @return list()
#' @noRd
api_update_permissions <- function (REQ, user_id, permissions) {
  
  DB              <- REQ[['DB']]
  project_id      <- REQ[['SESSION']][['project_id']]
  grantor_user_id <- REQ[['SESSION']][['user_id']]
  
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
#' @noRd
update_permissions <- function (DB, user_id, project_id, permissions, grantor_user_id = NULL) {
  
  stopifnot(is_one_of(permissions, c("none", "view", "edit", "any")))
  
  
  #________________________________________________________
  # Look up this permission entry (if it exists yet).
  #________________________________________________________
  sql <- "SELECT * FROM permissions WHERE user_id = ? AND project_id = ?"
  row <- db_query(DB, sql, "UPerm1", list(user_id, project_id))
  
  permission_id <- row[['permission_id']]
  
  
  if (identical(permissions, "none")) { # Revoke
    
    if (is.null(permission_id))
      stop_user("That user has no access to this project.")
    
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
#' Partially redact the username of email addresses with asterisks.
#' @return redacted_email
#' @noRd
redact_emails <- function (emails) {
  vapply(emails, FUN.VALUE = character(1), USE.NAMES = FALSE, function (email) {

    if (is.na(email)) return (NA_character_)
  
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

