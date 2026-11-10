
#______________________________________________________________________________
#' User is registering for a new account.
#' @return <response:session_data> or <response:swal>
#' 
api_create_account <- function (REQ, full_name, email, affiliation, password = NULL) {
  
  DB      <- REQ[['DB']]
  SMTP    <- REQ[['SMTP']]
  URL     <- REQ[['URL']]
  IP      <- REQ[['CLIENT']][['ip_address']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  
  #________________________________________________________
  # Choose a random password to email to the new user.
  #________________________________________________________
  if (!is.null(SMTP))
    password <- random_string(10)
  
  
  #________________________________________________________
  # Sanity check name, email, affiliation, and password.
  #________________________________________________________
  for (key in c("full_name", "email", "affiliation")) {
    val <- trimws(get(key))
    if (!is_scalar_character(val)) return (swal("Invalid value for ", key))
    if (!isTRUE(nchar(val) >= 3L)) return (swal(key, "must be at least 3 characters."))
    if (!isTRUE(nchar(val) < 60L)) return (swal(key, "must be less than 60 characters."))
    assign(key, val)
  }
  if (substr(tolower(full_name), 1, 5) %in% c("guest", "atima"))
    return (swal("Full name cannot start with 'guest' or 'atima'."))
  
  
  #________________________________________________________
  # Check for duplicate email addresses.
  #________________________________________________________
  sql <- "SELECT COUNT(*) FROM users WHERE email = ?"
  n   <- db_query(DB, sql, "ANAcct1", list(tolower(email)))
  if (n != 0) return (swal("This email address is already registered."))
  
  
  #________________________________________________________
  # Begin converting guest account to user account.
  #________________________________________________________
  db_update(
    DB           = DB, 
    table        = 'users', 
    id           = user_id, 
    err_code     = "ANAcct2",
    full_name    = full_name,
    email        = tolower(email),
    affiliation  = affiliation,
    is_guest     = !is.null(SMTP),
    password     = ifelse(is.null(SMTP), password_store(password), NA),
    alt_password = ifelse(is.null(SMTP), NA, password_store(password)) )
  
  
  
  #________________________________________________________
  # No SMTP configured - log the user in.
  #________________________________________________________
  if (is.null(SMTP))
    return (api_sign_in(REQ, email, password))
  
  
  
  #________________________________________________________
  # Send a verification email to the user.
  #________________________________________________________
  send_email(
    REQ     = REQ, 
    to      = email, 
    subject = "Welcome to atima!",
    message = blastula::md(
      text = sprintf(
        fmt = paste(
          sep = "\n\n", 
          "## Welcome %s!",
          "You can now log in to [atima](%s) with the following credentials:",
          "Email Address: %s",
          "Password: %s",
          "<span style='font-size:11px; font-style:italic'>",
          "If you did not sign up for an atima account, this email can be safely ignored.",
          "Account request originated from IP address %s",
          "</span>" ), full_name, URL, email, password, IP )) )
  
  
  return (swal(success = "Your password has been emailed to you."))
}


#______________________________________________________________________________
#' User is changing their account details.
#' @return list(swal)
api_update_account <- function (REQ, full_name, affiliation, new_password, password) {
  
  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  
  #________________________________________________________
  # Check for properly formatted arguments.
  #________________________________________________________
  if (identical(password, '')) return (swal("Your current password is required."))
  if (identical(new_password, '')) new_password <- password
  sc <- sanity_check(full_name, affiliation, password, new_password, assert = FALSE)
  if (isFALSE(sc)) return (swal(head(attr(sc, 'failures'), 1)))
  
  
  #________________________________________________________
  # Verify their current password.
  #________________________________________________________
  sql  <- "SELECT * FROM users WHERE user_id = ?"
  user <- db_query(DB, sql, "AUAcct1", list(user_id))
  if (!password_verify(trimws(password), user[['password']]))
    return (swal("Incorrect current password."))
  
  
  #________________________________________________________
  # Apply updates.
  #________________________________________________________
  db_update(
    DB           = DB, 
    table        = "users", 
    id           = user_id, 
    err_code     = "AUAcct2",
    full_name    = full_name,
    affiliation  = affiliation,
    password     = password_store(new_password),
    alt_password = NA )
  
  
  return (swal(success = "Your account details have been updated."))
}




#______________________________________________________________________________
#' Information needed when opening 'My Account' modal.
#' @return list(full_name, affiliation, email)
api_account_details <- function (REQ) {
  DB  <- REQ[['DB']]
  sql <- "SELECT full_name, affiliation, email FROM users WHERE user_id = ?"
  return (db_query(DB, sql, "AADeta1", list(REQ[['SESSION']][['user_id']])))
}




#______________________________________________________________________________
#' The user wants us to reset their password. Email them their new one.
#' @return swal()
api_reset_password <- function (REQ, email) {
  
  DB   <- REQ[['DB']]
  SMTP <- REQ[['SMTP']]
  IP   <- REQ[['CLIENT']][['ip_address']]
  
  
  if (is.null(SMTP))
    return (swal(error = "Password resets are not enabled."))
  
  
  #________________________________________________________
  # Sanity check the email address.
  #________________________________________________________
  stopifnot(is_scalar_character(email))
  email <- tolower(trimws(email))
  if (!isTRUE(nchar(email) >= 5L && nchar(email) <= 60L))
    return (swal("Email address must be between 5 and 60 characters long."))
  
  
  #________________________________________________________
  # Convert email address to user_id
  #________________________________________________________
  sql     <- "SELECT user_id FROM users WHERE email = ?"
  user_id <- db_query(DB, sql, "ARPass1", list(email))
  if (is.null(user_id))
    return (swal("No account found with that email address."))
  
  
  #________________________________________________________
  # Generate a new alternate random password.
  #________________________________________________________
  alt_password <- random_string(10)
  db_update(
    DB           = DB, 
    table        = 'users', 
    id           = user_id, 
    err_code     = "ARPass2",
    alt_password = password_store(alt_password) )
  
  
  #________________________________________________________
  # Generate a new alternate random password.
  #________________________________________________________
  send_email(
    REQ     = REQ, 
    to      = email, 
    subject = "atima password reset",
    message = blastula::md(
      text = sprintf(
        fmt = paste(
          sep = "\n\n", 
          "You can now log in with this alternate password: %s",
          "Once you log in using the alternate password, your old password will no longer work.",
          "<span style='font-size:11px; font-style:italic'>",
          "If you are not trying to reset your atima account password, this email can be safely ignored.",
          "Reset request originated from IP address %s",
          "</span>"), alt_password, IP )) )
  
  
  return (swal(success = "Your new password has been emailed to you."))
}



#______________________________________________________________________________
#' User is signing in from the modal prompt.
#' @return <response:session_data> or <response:swal>
#' 
api_sign_in <- function (REQ, email, password) {
  
  DB            <- REQ[['DB']]
  guest_uid     <- REQ[['SESSION']][['user_id']]
  is_guest      <- REQ[['SESSION']][['is_guest']]
  project_id    <- REQ[['SESSION']][['project_id']]
  auth_token_id <- REQ[['SESSION']][['auth_token_id']]
  session_id    <- REQ[['SESSION']][['session_id']]
  
  
  if (!is_guest)
    return (swal("This session is already logged in. (ASIn1)"))
  
  
  #________________________________________________________
  # Validate user's email / password credentials.
  #________________________________________________________
  user_id <- authenticate_password(DB, email, password)
  if (!is_scalar_integerish(user_id)) return (user_id)
  
  
  #________________________________________________________
  # Transfer auth_token ownership to user_id.
  #________________________________________________________
  sql <- "UPDATE auth_tokens SET user_id = ? WHERE auth_token_id = ?"
  db_query(DB, sql, "ASIn3", list(user_id, auth_token_id))
  
  
  
  #________________________________________________________
  # Transfer session ownership to user_id.
  #________________________________________________________
  sql <- "UPDATE sessions SET user_id = ? WHERE session_id = ?"
  db_query(DB, sql, "ASIn3", list(user_id, session_id))
  
  
  
  #________________________________________________________
  # Transfer view/edit permissions for active project.
  #________________________________________________________
  if (is_project_writable(DB, project_id, user_id = guest_uid)) {
    update_permissions(DB, user_id, project_id, "edit")
    
  } else if (!is_project_readable(DB, project_id, user_id)) {
    update_permissions(DB, user_id, project_id, "view")
  }
    
  
  
  #________________________________________________________
  # Reload this session as the new user.
  #________________________________________________________
  resume_session(REQ)
  
  
  resp <- get_session_data(REQ)
  
  return (resp)
}



#______________________________________________________________________________
#' User clicked on 'Log Out'.
#' @return list(CONF, BIOM, jstree_data)
#' 
api_log_out <- function (REQ) {
  
  DB            <- REQ[['DB']]
  session_id    <- REQ[['SESSION']][['session_id']]
  auth_token_id <- REQ[['SESSION']][['auth_token_id']]
  server_temp   <- REQ[['SESSION']][['server_temp']]
  
  
  #________________________________________________________
  # Revoke this auth_token.
  #________________________________________________________
  sql <- paste(
    "UPDATE sessions",
    " SET logout_utc = CURRENT_TIMESTAMP, auth_token_id = NULL",
    " WHERE session_id = ?" )
  db_query(DB, sql, "ALOut1", list(session_id))
  
  sql <- paste(
    "UPDATE sessions",
    " SET logout_utc = heartbeat_utc, auth_token_id = NULL",
    " WHERE auth_token_id = ?" )
  db_query(DB, sql, "ALOut2", list(auth_token_id))
  
  sql <- "DELETE FROM auth_tokens WHERE auth_token_id = ?"
  db_query(DB, sql, "ALOut3", list(auth_token_id))
  
  
  
  #________________________________________________________
  # Delete the publicly accessible temp files.
  #________________________________________________________
  unlink(server_temp, recursive = TRUE, expand = FALSE)
  
  
  #________________________________________________________
  # Create a new session and new guest user
  #________________________________________________________
  resp <- api_init_session(REQ)
  
  return (resp)
}



#______________________________________________________________________________
#' Try to log in using an email address and password. Tracks attempts/lockouts.
#' @return user_id on success or a <response:swal> otherwise.
authenticate_password <- function (DB, email, password) {
  
  email    <- trimws(email)
  password <- trimws(password)
  
  stopifnot(is_scalar_character(email))
  stopifnot(is_scalar_character(password))

  if (!isTRUE(nchar(email) > 3))    return (swal("Email address too short."))
  if (!isTRUE(nchar(password) > 3)) return (swal("Password too short."))
  
  
  #________________________________________________________
  # Reset lockouts.
  #________________________________________________________
  sql <- paste0(
    "UPDATE users SET n_attempts = 0, locked_utc = NULL",
    " WHERE locked_utc < datetime('now', '-5 minutes')" )
  db_query(DB, sql, "APass2")
  
  
  #________________________________________________________
  # Lookup this email address in the `users` table.
  #________________________________________________________
  sql  <- "SELECT * FROM users WHERE LOWER(email) = ?"
  user <- db_query(DB, sql, "APass1", list(tolower(email)))
  
  if (is.null(user))
    return (swal("No account found for that email address."))
  
  if (!is.na(user[['locked_utc']]))
    return (swal("Too many password attempts. Try again in 5 minutes."))
  
  
  #________________________________________________________
  # Handle verification login / password reset login.
  #________________________________________________________
  if (!is.na(user[['alt_password']])) {
    if (password_verify(password, user[['alt_password']])) {
      
      db_update(
        DB           = DB, 
        table        = 'users', 
        id           = user[['user_id']], 
        err_code     = "APass2",
        password     = user[['alt_password']],
        alt_password = NULL,
        is_guest     = FALSE )
      
      user[['password']] <- user[['alt_password']]
    }
  }
  
  
  
  #________________________________________________________
  # Incorrect password.
  #________________________________________________________
  if (!password_verify(password, user[['password']])) {
    
    # Lock them out.
    if (user[['n_attempts']] >= 4) {
      sql <- "UPDATE users SET locked_utc = CURRENT_TIMESTAMP WHERE user_id = ?"
      db_query(DB, sql, "APass3", list(user[['user_id']]))
      return (swal("Incorrect Password. Account locked for 5 minutes."))
    }
    
    # Increment attempts
    sql <- "UPDATE users SET n_attempts = n_attempts + 1 WHERE user_id = ?"
    db_query(DB, sql, "APass4", list(user[['user_id']]))
    msg <- "Incorrect Password. %i attempts left."
    return (swal(sprintf(msg, 4L - user[['n_attempts']])))
  }
  
  # Reset attempt counter on successful log in.
  if (user[['n_attempts']] > 0) {
    sql <- "UPDATE users SET n_attempts = 0 WHERE user_id = ?"
    db_query(DB, sql, "APass5", list(user[['user_id']]))
  }
  
  
  # Migrate user's old rsa key the first time they log in.
  # migrate_priv_key(DB, user[['user_id']], password)
  
  
  return (user[['user_id']])
}


#______________________________________________________________________________
#' Delete a user_id from all tables.
#' 
delete_account <- function (DB, user_id) {
  
  stopifnot(is_scalar_integerish(user_id))
  
  
  txn <- c(
    "UPDATE sessions    SET         user_id=NULL WHERE         user_id = ?",
    "UPDATE permissions SET grantor_user_id=NULL WHERE grantor_user_id = ?",
    
    "DELETE FROM resets      WHERE user_id = ?",
    "DELETE FROM auth_tokens WHERE user_id = ?",
    "DELETE FROM collections WHERE user_id = ?",
    "DELETE FROM permissions WHERE user_id = ?",
    "DELETE FROM users       WHERE user_id = ?" )
  
  tryCatch(
    
    expr = {
      db_query(DB, "BEGIN", "DAcc1")
      
      for (sql in txn)
        db_query(DB, sql, "DAcc2", list(user_id))
      
      db_query(DB, "COMMIT", "DAcc3")
    }, 
    
    error = function (e) ({
      try(silent = TRUE, db_query(DB, "ROLLBACK", "DAcc4"))
      stop(e)
    }) )
  
}



#______________________________________________________________________________
#' Convert a user_id into a full_name.
#' @return a full_name.
get_full_name <- function (DB, user_id) {
  
  if (is.null(user_id)) return (NULL)
  
  sql       <- "SELECT full_name FROM users WHERE user_id = ?"
  full_name <- db_query(DB, sql, "GFName1", list(user_id))
  
  return (full_name)
}
