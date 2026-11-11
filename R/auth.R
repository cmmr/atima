#______________________________________________________________________________
# Who is asking: authentication modes, auth tokens and the auth cookie.
#
# `run(auth = )` chooses one of two modes.
#
#   "none"  For one person on their own computer. The server only listens on
#           the loopback interface and only answers requests addressed to
#           it by a loopback name. There are no accounts: every session
#           belongs to one implicit owner.
#   "oidc"  For a shared server. Visitors start as guests and sign in
#           through an OpenID Connect provider (`R/auth-oidc.R`). A user is
#           the pair (issuer, sub) that the provider vouches for.
#
# Either way a browser is recognised by one cookie, `auth_token`: a random
# string of which the database keeps only the SHA-256. Tokens expire, and
# are replaced when the browser signs in or out. Each browser tab also has
# a session key, sent in the `x-session-key` header (`R/sessions.r`).
#
# What a signed-in user or a guest may do is not decided here; see
# `R/access.R`.
#______________________________________________________________________________


auth_modes <- c("none", "oidc")


#______________________________________________________________________________
#' Is `host` an address that only this computer can reach?
#' @noRd
is_loopback_host <- function (host) {
  if (!is_scalar_character(host) || is.na(host)) return (FALSE)
  host <- tolower(host)
  host %in% c("localhost", "::1", "[::1]") ||
    grepl("^127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", host)
}


#______________________________________________________________________________
#' The host name in a request's `Host` header, without the port.
#' @noRd
host_name <- function (host_header) {
  if (!is_scalar_character(host_header) || is.na(host_header)) return (NA_character_)
  if (startsWith(host_header, "["))
    return (sub("^(\\[[^]]*\\]).*$", "\\1", host_header))
  sub(":[0-9]*$", "", host_header)
}


#______________________________________________________________________________
#' Stop unless a request may be answered at all in the current mode.
#'
#' Without accounts, the only thing that keeps a web page on some other
#' site from reading the local data is that the browser treats it as a
#' different origin. A page can get around that by pointing its own domain
#' name at 127.0.0.1 ("DNS rebinding"), but its requests then still carry
#' that domain in the `Host` header, so those are refused.
#' @noRd
check_host <- function (REQ, request) {

  if (!identical(REQ[['CONFIG']][['auth']], "none")) return (invisible(TRUE))

  if (!is_loopback_host(host_name(request[['HTTP_HOST']])))
    stop_forbidden("This server only answers requests made to localhost.")

  invisible(TRUE)
}


#______________________________________________________________________________
#' Stop a POST that another web site made the browser send.
#'
#' Most API calls cannot be made from another site, because they need the
#' `x-session-key` header. Starting a session needs nothing, and its answer
#' sets the auth cookie, so a form on another site could replace a
#' visitor's cookie with a new guest's. Browsers say where a request comes
#' from (`Sec-Fetch-Site`, and `Origin` on every cross-origin POST); a POST
#' that says it comes from elsewhere is refused. Requests that say nothing,
#' such as those from scripts and command-line tools, are let through.
#' @noRd
check_origin <- function (REQ, request) {

  if (!identical(request[['REQUEST_METHOD']], "POST")) return (invisible(TRUE))

  header <- function (name) {
    value <- unname(request[['HEADERS']][name])
    if (length(value) != 1 || is.na(value)) NULL else tolower(trimws(value))
  }

  if (isTRUE(header("sec-fetch-site") %in% c("cross-site", "same-site")))
    stop_forbidden("This request came from another web site.")

  origin <- header("origin")

  if (!is.null(origin)) {
    host    <- tolower(request[['HTTP_HOST']] %||% "")
    allowed <- c(paste0("http://", host), paste0("https://", host), tolower(REQ[['CONFIG']][['public_url']]))
    if (!(origin %in% allowed))
      stop_forbidden("This request came from another web site.")
  }

  invisible(TRUE)
}


#______________________________________________________________________________
#' The state the auth code keeps while the server runs.
#'
#' @param mode  `"none"` or `"oidc"`.
#' @param oidc  For `"oidc"`: `list(issuer, client_id, client_secret,
#'              redirect_uri, admins)`. The client secret lives only here,
#'              never in the configuration that is passed to workers.
#' @return An environment.
#' @noRd
auth_new <- function (mode = "none", oidc = NULL) {
  stopifnot(is_one_of(mode, auth_modes))
  as.environment(list(
    mode     = mode,
    oidc     = oidc,
    provider = NULL,
    pending  = new.env(parent = emptyenv()) ))
}


#______________________________________________________________________________
#' The implicit owner of everything in `auth = "none"` mode. The row is made
#' the first time it is needed. The owner is an ordinary user, not a guest
#' (so cleanup never removes them) and not an administrator.
#'
#' A local install has one user, so whatever earlier guests and password
#' accounts left in the database (from before an upgrade) is that user's
#' own work, and the owner takes it over. Users who signed in through a
#' provider are left alone: a database with those came from a shared server.
#' @return A user_id.
#' @noRd
local_owner <- function (DB) {

  sql     <- "SELECT user_id FROM users WHERE issuer = 'local' AND sub = 'owner'"
  user_id <- db_query(DB, sql, "LOwn1")

  if (is.null(user_id))
    user_id <- db_insert(
      DB = DB, table = "users", err_code = "LOwn2",
      full_name = "Local user", issuer = "local", sub = "owner", is_guest = FALSE )

  user_id <- as.integer(user_id)

  earlier <- db_query(DB, "SELECT user_id FROM users WHERE issuer IS NULL", "LOwn3")

  for (other in earlier) {
    db_update(DB, "users", other, "LOwn4", is_guest = TRUE)
    adopt_guest(DB, other, user_id)
  }

  if (length(earlier) > 0)
    log_event("info", "local_owner_adopted", users = length(earlier))

  user_id
}


#______________________________________________________________________________
#' Issue a new auth token for a user.
#'
#' @param ttl  Seconds until it expires.
#' @return `list(auth_token, auth_token_id)`. The token itself is not kept.
#' @noRd
auth_token_new <- function (DB, user_id, ttl) {

  auth_token <- random_string(64)

  auth_token_id <- db_insert(
    DB             = DB,
    table          = "auth_tokens",
    err_code       = "ATNew1",
    user_id        = user_id,
    auth_token_sha = as.character(sha256(auth_token)),
    expires_utc    = sql_time(Sys.time() + ttl) )

  list(auth_token = auth_token, auth_token_id = as.integer(auth_token_id))
}


#______________________________________________________________________________
#' Look up the auth token a request carries.
#'
#' @return `list(auth_token_id, user_id, is_guest, expires_utc)`, or `NULL`
#'         if there is no such token or it has expired.
#' @noRd
auth_token_find <- function (DB, auth_token) {

  if (!isTRUE(grepl("^[a-zA-Z0-9]{64}$", auth_token))) return (NULL)

  sql <- paste0(
    "SELECT auth_token_id, user_id, is_guest, expires_utc",
    " FROM auth_tokens JOIN users USING (user_id)",
    " WHERE auth_token_sha = ? AND expires_utc > ?" )

  db_query(DB, sql, "ATFind1", list(as.character(sha256(auth_token)), sql_time(Sys.time())))
}


#______________________________________________________________________________
#' Revoke an auth token and close the sessions (browser tabs) that use it.
#' @noRd
auth_token_revoke <- function (DB, auth_token_id) {

  sql <- "UPDATE sessions SET logout_utc = CURRENT_TIMESTAMP, auth_token_id = NULL WHERE auth_token_id = ?"
  db_query(DB, sql, "ATRev1", list(auth_token_id))

  sql <- "DELETE FROM auth_tokens WHERE auth_token_id = ?"
  db_query(DB, sql, "ATRev2", list(auth_token_id))

  invisible(NULL)
}


#______________________________________________________________________________
#' The `Set-Cookie` header for an auth token.
#'
#' `HttpOnly` keeps it from scripts, `SameSite=Lax` keeps it out of requests
#' that other sites make (except a plain link to atima), and `Secure` is
#' added whenever the browser reached atima over HTTPS.
#'
#' @param auth_token  The token, or `NULL` to remove the cookie.
#' @param max_age     Seconds the browser should keep it.
#' @noRd
auth_cookie <- function (REQ, auth_token, max_age = 0) {
  cookie(
    name      = "auth_token",
    value     = auth_token %||% "deleted",
    max_age   = if (is.null(auth_token)) 0L else max(1L, as.integer(max_age)),
    path      = "/",
    same_site = "Lax",
    secure    = isTRUE(REQ[['CLIENT']][['https']]),
    http_only = TRUE )
}


#______________________________________________________________________________
#' Did this request reach atima over HTTPS?
#'
#' httpuv itself only speaks HTTP, so HTTPS means a reverse proxy in front.
#' The answer is yes when `public_url` says the site is served over HTTPS, or
#' when the header named by `forwarded_proto_header` (which must be one the
#' proxy sets itself, such as `X-Forwarded-Proto`) says this request was.
#' @noRd
request_is_https <- function (request, config) {

  if (isTRUE(startsWith(config[['public_url']] %||% "", "https://"))) return (TRUE)

  name <- config[['forwarded_proto_header']]
  if (is.null(name)) return (FALSE)

  value <- unname(request[['HEADERS']][tolower(name)])
  isTRUE(tolower(trimws(strsplit(value %||% "", ",", fixed = TRUE)[[1]][1])) == "https")
}


#______________________________________________________________________________
#' Record that a person has proved who they are, and give their browser a
#' new auth token.
#'
#' The user is found by (issuer, sub) or created. Their name, email and
#' affiliation follow what the provider says now. If the browser was a guest
#' until this moment, everything the guest had becomes the user's.
#'
#' @param issuer,sub  The identity.
#' @param profile     `list(full_name, email, affiliation)`; `email` and
#'                    `affiliation` may be `NULL`.
#' @param is_admin    `TRUE` or `FALSE` to set the flag, `NULL` to leave it.
#' @return `list(auth_token, user_id)`.
#' @noRd
sign_in <- function (REQ, issuer, sub, profile, is_admin = NULL) {

  DB <- REQ[['DB']]

  sql     <- "SELECT user_id FROM users WHERE issuer = ? AND sub = ?"
  user_id <- db_query(DB, sql, "SIn1", list(issuer, sub))

  if (is.null(user_id))
    user_id <- db_insert(DB, "users", "SIn2", issuer = issuer, sub = sub)

  user_id <- as.integer(user_id)

  db_update(
    DB          = DB,
    table       = "users",
    id          = user_id,
    err_code    = "SIn3",
    full_name   = profile[['full_name']],
    email       = profile[['email']],
    affiliation = profile[['affiliation']],
    is_guest    = FALSE )

  if (!is.null(is_admin))
    db_update(DB, "users", user_id, "SIn4", is_admin = isTRUE(is_admin))


  # Whoever this browser was before, it is not any more.
  previous <- auth_token_find(DB, REQ[['CLIENT']][['auth_token']])

  if (!is.null(previous)) {
    auth_token_revoke(DB, previous[['auth_token_id']])
    if (previous[['is_guest']] && !identical(previous[['user_id']], user_id))
      adopt_guest(DB, previous[['user_id']], user_id)
  }

  token <- auth_token_new(DB, user_id, REQ[['CONFIG']][['signin_ttl']])

  list(auth_token = token[['auth_token']], user_id = user_id)
}


#______________________________________________________________________________
#' Give everything a guest has to a user, then delete the guest.
#'
#' Collections and grants move over. Where both have a grant on the same
#' project the user keeps theirs, raised to editor if the guest was one.
#' @noRd
adopt_guest <- function (DB, guest_id, user_id) {

  db_query(DB, "UPDATE collections SET user_id = ? WHERE user_id = ?", "AGst1", list(user_id, guest_id))

  sql <- paste0(
    "UPDATE permissions SET is_editor = 1",
    " WHERE user_id = ? AND project_id IN (",
    "   SELECT project_id FROM permissions WHERE user_id = ? AND is_editor = 1)" )
  db_query(DB, sql, "AGst2", list(user_id, guest_id))

  sql <- paste0(
    "UPDATE permissions SET user_id = ?",
    " WHERE user_id = ? AND project_id NOT IN (",
    "   SELECT project_id FROM permissions WHERE user_id = ?)" )
  db_query(DB, sql, "AGst3", list(user_id, guest_id, user_id))

  sql <- paste0(
    "UPDATE last_access SET user_id = ?",
    " WHERE user_id = ? AND project_id NOT IN (",
    "   SELECT project_id FROM last_access WHERE user_id = ?)" )
  db_query(DB, sql, "AGst4", list(user_id, guest_id, user_id))

  # What is left of the guest (duplicate grants, tokens) goes with the row.
  db_query(DB, "DELETE FROM users WHERE user_id = ? AND is_guest = 1", "AGst5", list(guest_id))

  invisible(NULL)
}


#______________________________________________________________________________
#' Sign out: revoke the browser's auth token, which also closes every tab
#' that was using it, and remove the cookie. The page then starts again as
#' a guest. This does not end the person's session with the provider.
#' @return list(signed_out = TRUE), with the cookie removed.
#' @noRd
api_sign_out <- function (REQ) {

  session <- REQ[['SESSION']]

  auth_token_revoke(REQ[['DB']], session[['auth_token_id']])

  pool <- REQ[['POOL']]
  if (!is.null(pool)) pool_cancel_session(pool, session[['session_id']])

  unlink(session[['server_temp']], recursive = TRUE, expand = FALSE)

  log_event("info", "sign_out", user_id = session[['user_id']])

  response(list(signed_out = unbox(TRUE)), auth_cookie(REQ, NULL))
}


#______________________________________________________________________________
#' The signed-in user's own details, for an account menu.
#' @return list(full_name, affiliation, email, issuer)
#' @noRd
api_account_details <- function (REQ) {
  sql <- "SELECT full_name, affiliation, email, issuer FROM users WHERE user_id = ?"
  res <- db_query(REQ[['DB']], sql, "AADeta1", list(REQ[['SESSION']][['user_id']]), simplify = FALSE)
  lapply(as.list(res), unbox)
}
