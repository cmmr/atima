#______________________________________________________________________________
# Connected apps: what a person sees and controls of the AI apps that use
# atima for them.
#
#   * The connections themselves (`app_grants`, made in `R/oauth.R`): which
#     app, whether it may only read or also change things, when it was
#     connected and last used. Disconnecting one deletes it and its tokens,
#     so the app's next request is refused. Only a server with accounts has
#     connections; a local install lets in whatever is given its address.
#   * The record of changes (`app_changes`): one row for every change made
#     through a tool an app called, on both kinds of server. A row says
#     who, through which app, with which tool, to which project, and in one
#     sentence what changed. It is written by `tool_call()`
#     (`R/mcp-tools.R`) and by the upload route, never by a handler's own
#     choice, so a tool that changes data cannot forget it.
#   * The cap on changes: one connection (on a local install, the one user)
#     may make `app_changes_per_hour` changes in an hour. The record is
#     what is counted.
#______________________________________________________________________________


# Rows of the record shown on the page, and days a row is kept.
app_changes_shown <- 200L
app_changes_days  <- 365L


#______________________________________________________________________________
#' Record a change that an AI app made through a tool.
#'
#' @param caller      Who the tool was called for: `list(user_id, grant_id,
#'                    app)` (`mcp_caller()`).
#' @param tool        The tool's name.
#' @param summary     One sentence saying what changed.
#' @param project_id  The project that was changed, if one was.
#' @noRd
record_change <- function (DB, caller, tool, summary, project_id = NULL) {

  title <- NULL
  if (!is.null(project_id))
    title <- db_query(DB, "SELECT title FROM projects WHERE project_id = ?", "RChg1", list(project_id))

  db_insert(
    DB = DB, table = "app_changes", err_code = "RChg2",
    user_id       = caller[['user_id']],
    grant_id      = caller[['grant_id']],
    app           = caller[['app']],
    tool          = tool,
    project_id    = project_id,
    project_title = title,
    summary       = substr(summary, 1L, 500L) )

  log_event("info", "app_change", user_id = caller[['user_id']], grant_id = caller[['grant_id']], tool = tool, project_id = project_id)

  invisible(NULL)
}


#______________________________________________________________________________
#' Stop if the caller's connection has made as many changes in the last
#' hour as one connection may.
#' @noRd
check_change_cap <- function (REQ, caller) {

  cap <- REQ[['CONFIG']][['app_changes_per_hour']] %||% Inf
  if (!is.finite(cap)) return (invisible(TRUE))

  since <- sql_time(Sys.time() - 3600)

  made <- if (is.null(caller[['grant_id']])) {
    sql <- "SELECT COUNT(*) FROM app_changes WHERE user_id = ? AND grant_id IS NULL AND made_utc > ?"
    db_query(REQ[['DB']], sql, "CCap1", list(caller[['user_id']], since))
  } else {
    sql <- "SELECT COUNT(*) FROM app_changes WHERE grant_id = ? AND made_utc > ?"
    db_query(REQ[['DB']], sql, "CCap2", list(caller[['grant_id']], since))
  }

  if (made >= cap)
    stop_http(429L, sprintf(paste(
      "This app has made %i changes in the last hour, which is the most one connected app may make.",
      "Nothing was changed. Wait before changing anything else; reading and analysing still work." ), as.integer(made)))

  invisible(TRUE)
}


#______________________________________________________________________________
#' The caller's connected apps and the record of what apps changed.
#'
#' @return `list(apps, changes)`. `apps` is empty on a server without
#'         accounts.
#' @noRd
api_apps_list <- function (REQ) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]

  sql <- paste0(
    "SELECT grant_id, client_id, client_name, redirect_host, scope, created_utc, used_utc, expires_utc",
    " FROM app_grants WHERE user_id = ? AND expires_utc > ?",
    " ORDER BY created_utc DESC, grant_id DESC" )
  grants <- db_query(DB, sql, "AAList1", list(user_id, sql_time(Sys.time())), simplify = FALSE)

  apps <- lapply(seq_len(nrow(grants)), function (i) list(
    grant_id      = unbox(grants[i, 'grant_id']),
    name          = unbox(grants[i, 'client_name']),
    host          = unbox(url_host(grants[i, 'client_id'])),
    redirect_host = unbox(grants[i, 'redirect_host']),
    writes        = unbox("write" %in% oauth_scope_list(grants[i, 'scope'])),
    created_utc   = unbox(sql_time(grants[i, 'created_utc'])),
    used_utc      = unbox(if (is.na(grants[i, 'used_utc'])) NA else sql_time(grants[i, 'used_utc'])),
    expires_utc   = unbox(sql_time(grants[i, 'expires_utc'])) ))

  sql <- paste0(
    "SELECT made_utc, app, tool, project_title, summary FROM app_changes",
    " WHERE user_id = ? ORDER BY made_utc DESC, change_id DESC LIMIT ?" )
  made <- db_query(DB, sql, "AAList2", list(user_id, app_changes_shown), simplify = FALSE)

  changes <- lapply(seq_len(nrow(made)), function (i) list(
    made_utc = unbox(sql_time(made[i, 'made_utc'])),
    app      = unbox(made[i, 'app']),
    tool     = unbox(made[i, 'tool']),
    project  = unbox(made[i, 'project_title']),
    summary  = unbox(made[i, 'summary']) ))

  list(apps = apps, changes = changes)
}


#______________________________________________________________________________
#' Disconnect one of the caller's apps, or all of them. The router has
#' checked that a connection named is the caller's.
#'
#' @param grant_id  The connection, or `NULL` for all.
#' @return list(disconnected = <number>)
#' @noRd
api_apps_disconnect <- function (REQ, grant_id = NULL) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]

  n <- if (is.null(grant_id)) {
    delete_where(DB, "app_grants", "user_id = ?", list(user_id))
  } else {
    delete_where(DB, "app_grants", "grant_id = ? AND user_id = ?", list(grant_id, user_id))
  }

  log_event("info", "app_disconnected", user_id = user_id, grant_id = grant_id, by = "user", n = n)

  list(disconnected = unbox(n))
}


#______________________________________________________________________________
#' Cleanup: connections that ran out, tokens that expired, upload tickets
#' that are a day old, and rows of the record older than a year.
#' @return The number of rows deleted.
#' @noRd
cleanup_apps <- function (DB, now) {

  time <- sql_time(now)

  delete_where(DB, "app_grants",  "expires_utc < ?", list(time)) +
  delete_where(DB, "app_tokens",  "expires_utc < ?", list(time)) +
  delete_where(DB, "app_uploads", "expires_utc < ?", list(sql_time(now - 86400))) +
  delete_where(DB, "app_changes", "made_utc < ?",    list(sql_time(now - app_changes_days * 86400)))
}
