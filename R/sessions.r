

#______________________________________________________________________________
#' Client asking us to not garbage collect their session.
#'
#' Loading the session, which the router has already done, records that it
#' is alive (`resume_session()`), so there is nothing left to do here.
#' @return list()
#' @noRd
api_heartbeat <- function (REQ) {
  return (list())
}


#______________________________________________________________________________
#' Cancel whatever jobs the session has queued or running. The browser calls
#' this when the page is closed or the user stops a plot.
#' @return list(cancelled = <number of jobs>)
#' @noRd
api_abort <- function (REQ) {

  pool <- REQ[['POOL']]
  n    <- if (is.null(pool)) 0L else pool_cancel_session(pool, REQ[['SESSION']][['session_id']])

  return (list(cancelled = unbox(n)))
}


#______________________________________________________________________________
#' Start a session for a browser tab.
#'
#' Who the tab belongs to comes from the browser's auth cookie. Without a
#' valid one, the browser becomes a new guest (or, in `auth = "none"` mode,
#' the owner) and is given a cookie.
#'
#' @param access_key  The project key in the page's URL, if any: a public
#'                    key, or a private key (a share link).
#' @return <response:session_data>
#' @noRd
api_init_session <- function (REQ, access_key = NULL) {

  DB     <- REQ[['DB']]
  CONFIG <- REQ[['CONFIG']]
  local  <- identical(CONFIG[['auth']], "none")


  #________________________________________________________
  # Who is this browser?
  #________________________________________________________
  token <- auth_token_find(DB, REQ[['CLIENT']][['auth_token']])
  owner <- if (local) local_owner(DB)

  if (local && !is.null(token) && !identical(token[['user_id']], owner))
    token <- NULL

  if (is.null(token)) {

    if (local) {
      user_id <- owner
    } else {
      user_id <- db_query(DB, "INSERT INTO users DEFAULT VALUES", "AISess2")
      db_update(DB, "users", user_id, "AISess3", full_name = sprintf("Guest %i", user_id))
    }

    ttl           <- if (local) CONFIG[['signin_ttl']] else CONFIG[['guest_ttl']]
    issued        <- auth_token_new(DB, user_id, ttl)
    auth_token    <- issued[['auth_token']]
    auth_token_id <- issued[['auth_token_id']]

  } else {

    user_id       <- token[['user_id']]
    auth_token    <- REQ[['CLIENT']][['auth_token']]
    auth_token_id <- token[['auth_token_id']]

    # A guest stays known for as long as they keep coming back.
    if (token[['is_guest']])
      db_update(
        DB, "auth_tokens", auth_token_id, "AISess4",
        expires_utc = sql_time(Sys.time() + CONFIG[['guest_ttl']]) )
  }


  #________________________________________________________
  # Decide which project to load.
  #________________________________________________________
  project_id <- NULL

  # The project named in the page's URL, e.g. /hmp50
  if (!is.null(access_key) && nzchar(access_key))
    project_id <- open_by_key(DB, access_key, user_id)

  # Otherwise the last project this user viewed.
  if (is.null(project_id)) {
    sql <- "SELECT project_id FROM permissions
        LEFT JOIN last_access USING (user_id, project_id)
        WHERE user_id = ? ORDER BY `viewed_utc` DESC LIMIT 1"
    project_id <- db_query(DB, sql, "AISess6", list(user_id))
  }

  # Otherwise the oldest public project.
  if (is.null(project_id)) {
    sql <- "SELECT project_id FROM projects WHERE public_key IS NOT NULL ORDER BY project_id LIMIT 1"
    project_id <- db_query(DB, sql, "AISess9")
  }

  if (is.null(project_id))
    stop_not_found("There is no project to open yet.")


  #________________________________________________________
  # Assign a new session_id. The session key also opens the
  # session's temporary files and its unsaved working copy,
  # so it has to be unguessable.
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
  session_key <- sprintf("%i%s", session_id, random_string(24))
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
      "  auth_token_id, auth_token_sha, expires_utc,",
      "  user_id, full_name, is_guest, is_admin,",
      "  draft_id,",
      "    drafts.full_bf_id as full_bf_id,",
      "    drafts.rare_bf_id as rare_bf_id,",
      "  project_id,",
      "    orig_bf_id, title, description, access_key,",
      "    projects.rare_bf_id as proj_rare_bf_id,",
      "    projects.public_key as public_key,",
      "  permission_id, is_editor",
      " FROM sessions",
      "  LEFT JOIN auth_tokens USING (auth_token_id, user_id)",
      "  LEFT JOIN users       USING (user_id)",
      "  LEFT JOIN drafts      USING (draft_id)",
      "  LEFT JOIN projects    USING (project_id)",
      "  LEFT JOIN permissions USING (project_id, user_id)",
      " WHERE session_key = ? AND auth_token_sha = ? AND expires_utc > ?",
      "  AND logout_utc IS NULL AND auth_token_id IS NOT NULL" )
    
    sha <- as.character(sha256(auth_token))
    return (db_query(DB, sql, "RSess1", list(session_key, sha, sql_time(Sys.time()))))
  })
  
  if (!is.list(session))
    stop_unauthorized("This session has expired. Please reload the page.")
  
  
  
  #________________________________________________________
  # Additional session information to pass back.
  #________________________________________________________
  session[['auth_token']]  <- auth_token
  session[['server_temp']] <- paste0(TEMP_DIR, "/", session[['session_key']])
  session[['client_temp']] <- paste0("/tmp",   "/", session[['session_key']])
  session[['is_public']]   <- !is.na(session[['public_key']])
  session[['project_key']] <- if (session[['is_public']]) session[['public_key']] else session[['access_key']]
  session[['is_saved']]    <- identical(session[['rare_bf_id']], session[['proj_rare_bf_id']])
  session[['draft_key']]   <- ifelse(
    test = session[['is_saved']], 
    yes  = session[['project_key']], 
    no   = sprintf("unsaved/%s", session[['session_key']]) )
  
  
  #________________________________________________________
  # What this session may do with its open project. The
  # router compares `access` with each route's permission.
  #________________________________________________________
  session[['is_admin']]  <- isTRUE(session[['is_admin']])
  session[['access']]    <- project_access(DB, session[['project_id']], session[['user_id']])
  session[['is_editor']] <- identical(session[['access']], "editor")
  
  
  
  #________________________________________________________
  # Make sure the temporary directory exists.
  #________________________________________________________
  if (!dir.exists(session[['server_temp']]))
    dir.create(session[['server_temp']], recursive = TRUE)
  
  
  
  #________________________________________________________
  # Record that the session and its user are alive. The
  # cleanup timer removes sessions and guests that have not
  # been for a while.
  #________________________________________________________
  user_id    <- session[['user_id']]
  project_id <- session[['project_id']]

  sql <- "UPDATE sessions SET heartbeat_utc = CURRENT_TIMESTAMP WHERE session_id = ?"
  db_query(DB, sql, "RSess3", list(session[['session_id']]))

  sql <- "UPDATE users SET seen_utc = CURRENT_TIMESTAMP WHERE user_id = ?"
  db_query(DB, sql, "RSess4", list(user_id))


  #________________________________________________________
  # Track last access for each user/project combo.
  #________________________________________________________
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
#' @return <response:session_data>, or a job that leads to one.
#' @noRd
get_session_data <- function (REQ) {

  with_biom_data(REQ, function (BIOM) {

    auth_token  <- REQ[['SESSION']][['auth_token']]
    session_key <- REQ[['SESSION']][['session_key']]

    # The browser keeps the cookie for as long as the token is valid.
    expires     <- REQ[['SESSION']][['expires_utc']]
    max_age     <- as.numeric(difftime(expires, Sys.time(), units = "secs"))
    cookie_hdr  <- auth_cookie(REQ, auth_token, max_age)
    sess_header <- header('x-session-key' = session_key, expose = TRUE)

    body <- list(
      jstree_data = compile_jstree_data(REQ),
      BIOM        = BIOM,
      CONF        = list(
        auth      = unbox(REQ[['CONFIG']][['auth']]),
        user_id   = unbox(REQ[['SESSION']][['user_id']]),
        full_name = unbox(REQ[['SESSION']][['full_name']]),
        is_guest  = unbox(REQ[['SESSION']][['is_guest']]),
        is_admin  = unbox(REQ[['SESSION']][['is_admin']]) ))

    response(body, cookie_hdr, sess_header)
  })
}
