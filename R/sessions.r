

#______________________________________________________________________________
#' Client asking us to not garbage collect their session.
#' @return list()
#' @noRd
api_heartbeat <- function (REQ) {
  
  DB         <- REQ[['DB']]
  session_id <- REQ[['SESSION']][['session_id']]
  
  sql <- paste0(
    "UPDATE sessions",
    " SET heartbeat_utc = CURRENT_TIMESTAMP",
    " WHERE session_id = ?" )
  db_query(DB, sql, "AHear1", list(session_id))
  
  return (list())
}



#______________________________________________________________________________
#' Loading client-side data for the first time.
#' @return <response:session_data>
#' @noRd
api_init_session <- function (REQ, access_key = NULL) {
  
  DB <- REQ[['DB']]
  
  
  
  #________________________________________________________
  # See if the headers have a valid auth_token.
  #________________________________________________________
  auth_token    <- REQ[['CLIENT']][['auth_token']]
  auth_token_id <- NULL
  user_id       <- NULL
  if (identical(nchar(auth_token), 64L)) {
    
    sql <- paste0(
      "SELECT auth_token_id, user_id FROM auth_tokens",
      " WHERE auth_token_sha = ?" )
    sha <- as.character(sha256(auth_token))
    res <- db_query(DB, sql, "AISess1", list(sha))
    
    if (!is.null(res)) {
      user_id       <- res[['user_id']]
      auth_token_id <- res[['auth_token_id']]
    }
  }
  
  
  
  #________________________________________________________
  # No valid auth_token. Create a new auth_token and user.
  #________________________________________________________
  if (is.null(user_id)) {
    
    
    #________________________________________________________
    # Create a new guest user.
    #________________________________________________________
    user_id    <- db_query(DB, "INSERT INTO USERS DEFAULT VALUES", "AISess2")
    full_name  <- sprintf("Guest %i", user_id)
    db_update(DB, "users", user_id, "AISess3", full_name)
    
    
    #________________________________________________________
    # Create a new authentication token.
    #________________________________________________________
    auth_token     <- random_string(64)
    auth_token_sha <- as.character(sha256(auth_token))
    auth_token_id  <- db_insert(
      DB             = DB,
      table          = "auth_tokens",
      err_code       = "AISess4",
      user_id        = user_id,
      auth_token_sha = auth_token_sha)
  }
  
  
  #________________________________________________________
  # Decide which project to load.
  #________________________________________________________
  project_id <- local({
    
    pid <- NULL
    
    
    #________________________________________________________
    # Load the project named in the page's URL, e.g. /hmp50
    #________________________________________________________
    if (!is.null(access_key) && nzchar(access_key))
      pid <- local({
        
        if (!sanity_check(access_key, assert = FALSE))
          return (NULL)
        
        sql <- "SELECT project_id FROM projects WHERE access_key = ?"
        pid <- db_query(DB, sql, "AISess5", list(access_key))
        
        return (pid)
      })
    
    
    #________________________________________________________
    # Default to the last project this user viewed.
    #________________________________________________________
    if (is.null(pid))
      pid <- local({
        sql <- "SELECT project_id FROM permissions
            LEFT JOIN last_access USING (user_id, project_id)
            WHERE user_id = ? ORDER BY `viewed_utc` DESC LIMIT 1"
        pid <- db_query(DB, sql, "AISess6", list(user_id))
        return (pid)
      })
    
    
    #________________________________________________________
    # Otherwise the oldest public project.
    #________________________________________________________
    if (is.null(pid))
      pid <- local({
        sql <- "SELECT project_id FROM projects WHERE is_public = 1 ORDER BY project_id LIMIT 1"
        pid <- db_query(DB, sql, "AISess9")
        return (pid)
      })
    
    if (is.null(pid))
      stop_not_found("There is no project to open yet.")
    
    
    return (pid)
  })
  
  
  if (!is_project_readable(DB, project_id, user_id))
    update_permissions(DB, user_id, project_id, "view")
  
  
  
  #________________________________________________________
  # Assign a new session_id.
  #________________________________________________________
  session_id <- db_insert(
    DB            = DB,
    table         = "sessions",
    err_code      = "AISess7",
    auth_token_id = auth_token_id,
    user_id       = user_id,
    draft_id      = create_draft(DB, project_id),
    ip_address    = REQ[['CLIENT']][['ip_address']] )
  
  sql         <- "UPDATE sessions SET session_key = ? WHERE session_id = ?"
  session_key <- sprintf("%i%s", session_id, random_string(8))
  db_query(DB, sql, "AISess8", list(session_key, session_id))
  
  
  #________________________________________________________
  # Load the new session.
  #________________________________________________________
  resume_session(REQ, auth_token, session_key)
  
  resp <- get_session_data(REQ)
  
  return (resp)
}



#______________________________________________________________________________
#' Sessions track the current state of a single browser tab.
#' @return list(session_id, user_id, project_id, auth_token_id, server_temp, client_temp) or NULL
#' @noRd
resume_session <- function (REQ, auth_token = NULL, session_key = NULL) {
  
  DB       <- REQ[['DB']]
  TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]
  
  if (is.null(auth_token))  auth_token  <- REQ[['CLIENT']][['auth_token']]
  if (is.null(session_key)) session_key <- REQ[['CLIENT']][['session_key']]
  
  if (!isTRUE(nzchar(auth_token)) || !isTRUE(nzchar((session_key))))
    stop_unauthorized("This session has expired. Please reload the page.")
  
  session <- local({
    
    sql <- paste0(
      "SELECT",
      "  session_id, session_key,",
      "  auth_token_id, auth_token_sha,",
      "  user_id, full_name, is_guest, is_admin,",
      "  draft_id,",
      "    drafts.full_bf_id as full_bf_id,",
      "    drafts.rare_bf_id as rare_bf_id,",
      "  project_id,",
      "    orig_bf_id, title, description, access_key,",
      "    projects.rare_bf_id as proj_rare_bf_id,",
      "    projects.is_public  as is_public,",
      "  permission_id, is_editor",
      " FROM sessions",
      "  LEFT JOIN auth_tokens USING (auth_token_id, user_id)",
      "  LEFT JOIN users       USING (user_id)",
      "  LEFT JOIN drafts      USING (draft_id)",
      "  LEFT JOIN projects    USING (project_id)",
      "  LEFT JOIN permissions USING (project_id, user_id)",
      " WHERE session_key = ? AND auth_token_sha = ?",
      "  AND logout_utc IS NULL AND auth_token_id IS NOT NULL" )
    
    sha <- as.character(sha256(auth_token))
    return (db_query(DB, sql, "RSess1", list(session_key, sha)))
  })
  
  if (!is.list(session))
    stop_unauthorized("This session has expired. Please reload the page.")
  
  
  
  #________________________________________________________
  # Additional session information to pass back.
  #________________________________________________________
  session[['auth_token']]  <- auth_token
  session[['server_temp']] <- paste0(TEMP_DIR, "/", session[['session_key']])
  session[['client_temp']] <- paste0("/tmp",   "/", session[['session_key']])
  session[['project_key']] <- session[['access_key']]
  session[['is_saved']]    <- identical(session[['rare_bf_id']], session[['proj_rare_bf_id']])
  session[['draft_key']]   <- ifelse(
    test = session[['is_saved']], 
    yes  = session[['access_key']], 
    no   = sprintf("unsaved/%s", session[['session_key']]) )
  
  
  #________________________________________________________
  # What this session may do with its open project. The
  # router compares `access` with each route's permission.
  #________________________________________________________
  session[['is_public']] <- isTRUE(session[['is_public']])
  session[['is_admin']]  <- isTRUE(session[['is_admin']])
  session[['access']]    <- project_access(DB, session[['project_id']], session[['user_id']])
  session[['is_editor']] <- identical(session[['access']], "editor")
  
  
  
  #________________________________________________________
  # Make sure the temporary directory exists.
  #________________________________________________________
  if (!dir.exists(session[['server_temp']]))
    dir.create(session[['server_temp']], recursive = TRUE)
  
  
  
  #________________________________________________________
  # Track last access for each user/project combo.
  #________________________________________________________
  user_id    <- session[['user_id']]
  project_id <- session[['project_id']]
  if (!is.na(project_id)) {
    sql <- paste0(
      "INSERT INTO last_access (user_id, project_id) VALUES (?, ?)",
      " ON CONFLICT (user_id, project_id)",
      " DO UPDATE SET viewed_utc = CURRENT_TIMESTAMP" )
    db_query(DB, sql, "RSess2", list(user_id, project_id))
  }
  
  
  REQ[['SESSION']] <- session
  
  invisible()
}



#______________________________________________________________________________
#' Client-side data.
#' @return <response:session_data>
#' @noRd
get_session_data <- function (REQ) {
  
  auth_token  <- REQ[['SESSION']][['auth_token']]
  session_key <- REQ[['SESSION']][['session_key']]
  
  # Without a path, browsers would only send the cookie back to URLs
  # under the one that set it (/api/session/).
  auth_cookie <- cookie(auth_token, max_age = Inf, http_only = TRUE, path = "/")
  sess_header <- header('x-session-key' = session_key, expose = TRUE)
  
  body <- list(
    jstree_data = compile_jstree_data(REQ), 
    BIOM        = get_biom_data(REQ), 
    CONF        = list(
      user_id         = unbox(REQ[['SESSION']][['user_id']]),
      is_guest        = unbox(REQ[['SESSION']][['is_guest']]),
      is_admin        = unbox(REQ[['SESSION']][['is_admin']]) ))
  
  resp <- response(body, auth_cookie, sess_header)
  
  return (resp)
}

