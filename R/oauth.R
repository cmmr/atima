#______________________________________________________________________________
# Signing in for AI apps: atima as an OAuth 2.1 authorization server.
#
# On a shared server (`auth = "oidc"`) every request to the Model Context
# Protocol endpoint (`/mcp`, `R/mcp.R`) needs an access token. An app gets
# one the way the MCP specification (revision 2026-07-28, "Authorization")
# lays out:
#
#   1. Its first request has no token and is answered 401 with a
#      `WWW-Authenticate` header that points at the protected resource
#      metadata (RFC 9728), which names this server as the authorization
#      server. The app then reads the authorization server metadata
#      (RFC 8414).
#   2. The app sends the person's browser to `GET /oauth/authorize` with a
#      PKCE challenge (S256) and the resource it wants a token for
#      (RFC 8707). The app says who it is with a Client ID Metadata
#      Document: its `client_id` is an https address, and the JSON document
#      there names the app and the addresses it may be returned to. Dynamic
#      Client Registration, which the specification has deprecated, is not
#      offered, and every app is a public client (no secret).
#   3. The person signs in through the server's OpenID Connect provider if
#      they have not (`R/auth-oidc.R`), and is shown the approval page:
#      which app is asking, where it will be returned to, and the choice
#      between letting it read and letting it also change things. Approval
#      is asked every time; nothing is remembered from an earlier one.
#   4. `POST /oauth/approve` returns the browser to the app with a code (and
#      `iss`, RFC 9207). The app exchanges the code and its PKCE verifier
#      at `POST /oauth/token` for an access token and a refresh token.
#   5. The access token lasts an hour. The refresh token is replaced each
#      time it is used; one that is used twice ends the connection, since
#      that is what a stolen token looks like. A connection that is not
#      used for `app_days` ends by itself, and the person can end it from
#      the "Connected apps" page (`R/apps.R`), or the app with
#      `POST /oauth/revoke` (RFC 7009).
#
# A connection is a row of `app_grants`; its tokens are rows of
# `app_tokens`, kept as SHA-256 only. Unfinished authorizations and codes
# live in memory for minutes, like unfinished sign-ins.
#
# A bearer token is the only credential `/mcp` accepts on a shared server:
# cookies are not looked at there, and bearer tokens are accepted nowhere
# else. Tokens reach handlers wrapped in `secret()`, so they cannot be
# logged.
#
# Scopes: `read` lets an app see the person's projects and run analyses;
# `write` lets it also upload, change, share, publish and delete. What the
# person chooses on the approval page decides, whatever the app asked for,
# and reading only is what the page has chosen for them to begin with.
#______________________________________________________________________________


# What an app may be allowed to do.
oauth_scopes <- c("read", "write")

# Seconds an access token, an authorization code, and an authorization that
# is waiting for the person last.
oauth_access_ttl  <- 3600
oauth_code_ttl    <- 60
oauth_pending_ttl <- 600

# Most unfinished authorizations and codes kept at once.
oauth_pending_max <- 5000L

# A refresh token that was just replaced may be presented once more for
# this many seconds without ending the connection: an app that refreshes
# from two places at once is not a thief.
oauth_reuse_grace <- 60

# Client ID Metadata Documents: seconds to wait for one, the most bytes to
# accept, how long to remember one, and how many to remember.
oauth_client_timeout <- 5
oauth_client_bytes   <- 65536L
oauth_client_ttl     <- 3600
oauth_client_max     <- 200L


#______________________________________________________________________________
#' The state the authorization server keeps in memory.
#' @noRd
oauth_state <- function () {
  as.environment(list(
    requests = new.env(parent = emptyenv()),
    codes    = new.env(parent = emptyenv()),
    clients  = new.env(parent = emptyenv()) ))
}


#' This server's issuer identifier, and the resource its tokens are for.
#' @noRd
oauth_issuer   <- function (CONFIG) CONFIG[['public_url']]
oauth_resource <- function (CONFIG) paste0(CONFIG[['public_url']], "/mcp")

#' Where the protected resource metadata is.
#' @noRd
oauth_resource_metadata <- function (CONFIG) {
  paste0(CONFIG[['public_url']], "/.well-known/oauth-protected-resource/mcp")
}


#______________________________________________________________________________
#' A response that carries JSON and must not be stored.
#' @noRd
oauth_json <- function (body, status = 200L, headers = list()) {
  response(mcp_json(body), as.integer(status), headers = c(headers, list('Cache-Control' = "no-store")))
}


#' Stop with an OAuth error (RFC 6749 section 5.2).
#' @param error        The error code, such as `"invalid_grant"`.
#' @param description  What went wrong, for the app's developer.
#' @noRd
stop_oauth <- function (error, description, status = 400L) {
  stop(structure(
    class = c("oauth_error", "error", "condition"),
    list(message = description, call = NULL, error = error, status = as.integer(status)) ))
}


#' Remove the entries of an in-memory store that are older than `ttl`
#' seconds, and stop if it is full.
#' @noRd
oauth_sweep <- function (store, ttl) {

  cutoff <- Sys.time() - ttl
  for (key in ls(store))
    if (store[[key]][['created']] < cutoff) rm(list = key, envir = store)

  if (length(store) >= oauth_pending_max)
    stop_http(503L, "Too many apps are connecting right now. Please try again in a few minutes.")

  invisible(NULL)
}


#' Take an entry out of an in-memory store, if it is there and not older
#' than `ttl` seconds.
#' @param keep  Leave it in the store?
#' @noRd
oauth_take <- function (store, key, ttl, keep = FALSE) {

  if (!is_scalar_character(key) || is.na(key) || !exists(key, envir = store, inherits = FALSE)) return (NULL)

  entry <- store[[key]]
  if (!keep) rm(list = key, envir = store)

  if (entry[['created']] < Sys.time() - ttl) return (NULL)

  entry
}


#______________________________________________________________________________
#' `GET /.well-known/oauth-protected-resource` (and `.../mcp`): what the
#' MCP endpoint is, and who issues tokens for it (RFC 9728).
#' @noRd
oauth_protected_resource <- function (REQ) {

  CONFIG <- REQ[['CONFIG']]

  oauth_json(list(
    resource                 = oauth_resource(CONFIG),
    authorization_servers    = list(oauth_issuer(CONFIG)),
    scopes_supported         = as.list(oauth_scopes),
    bearer_methods_supported = list("header"),
    resource_name            = "ATIMA" ))
}


#______________________________________________________________________________
#' `GET /.well-known/oauth-authorization-server`: how an app signs a person
#' in (RFC 8414).
#' @noRd
oauth_server_metadata <- function (REQ) {

  CONFIG <- REQ[['CONFIG']]
  url    <- function (path) paste0(CONFIG[['public_url']], path)

  oauth_json(list(
    issuer                                         = oauth_issuer(CONFIG),
    authorization_endpoint                         = url("/oauth/authorize"),
    token_endpoint                                 = url("/oauth/token"),
    revocation_endpoint                            = url("/oauth/revoke"),
    response_types_supported                       = list("code"),
    response_modes_supported                       = list("query"),
    grant_types_supported                          = list("authorization_code", "refresh_token"),
    code_challenge_methods_supported               = list("S256"),
    token_endpoint_auth_methods_supported          = list("none"),
    revocation_endpoint_auth_methods_supported     = list("none"),
    scopes_supported                               = as.list(oauth_scopes),
    client_id_metadata_document_supported          = TRUE,
    authorization_response_iss_parameter_supported = TRUE ))
}


#______________________________________________________________________________
# Apps: Client ID Metadata Documents.
#______________________________________________________________________________


#' Is this a network address on the public internet? Addresses of this
#' computer, of private networks and of link-local, shared and multicast
#' ranges are not, in IPv4 or IPv6.
#' @noRd
is_public_address <- function (address) {

  if (!is_scalar_character(address) || is.na(address)) return (FALSE)

  address <- tolower(gsub("^\\[|\\]$", "", address))

  if (grepl("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", address)) {

    o <- as.integer(strsplit(address, ".", fixed = TRUE)[[1]])
    if (any(o > 255L)) return (FALSE)

    return (!(
      o[1] == 0L || o[1] == 10L || o[1] == 127L || o[1] >= 224L ||
      (o[1] == 100L && o[2] >= 64L && o[2] <= 127L) ||
      (o[1] == 169L && o[2] == 254L) ||
      (o[1] == 172L && o[2] >= 16L && o[2] <= 31L) ||
      (o[1] == 192L && o[2] == 0L && o[3] == 0L) ||
      (o[1] == 192L && o[2] == 168L) ||
      (o[1] == 198L && o[2] %in% c(18L, 19L)) ))
  }

  if (!grepl("^[0-9a-f:.]+$", address) || !grepl(":", address, fixed = TRUE)) return (FALSE)

  # Unspecified, loopback, IPv4 inside IPv6, unique local, link-local,
  # multicast.
  !(address %in% c("::", "::1") ||
    grepl("^(::ffff:|64:ff9b:|f[cd]|fe[89ab]|ff)", address) ||
    grepl(".", address, fixed = TRUE))
}


#' The addresses a host name stands for. A separate function so that tests
#' can replace it.
#' @return A character vector, empty if the name cannot be resolved.
#' @noRd
host_addresses <- function (host) {

  host <- gsub("^\\[|\\]$", "", host)

  if (grepl("^[0-9.]+$", host) || grepl(":", host, fixed = TRUE)) return (host)

  found <- tryCatch(curl::nslookup(host, multiple = TRUE, error = FALSE), error = function (e) NULL)
  as.character(found %||% character(0))
}


#' Is this an address an app may be returned to: https, or http on this
#' computer (an app that listens on a local port)?
#' @noRd
oauth_redirect_valid <- function (uri) {

  if (!is_scalar_character(uri) || is.na(uri) || nchar(uri) > 500L) return (FALSE)
  if (!grepl("^https?://[A-Za-z0-9._~:/?@!$&()*+,;=%\\[\\]-]+$", uri, perl = TRUE)) return (FALSE)

  url <- tryCatch(httr2::url_parse(uri), error = function (e) NULL)
  if (is.null(url) || is.null(url[['hostname']]) || !is.null(url[['fragment']])) return (FALSE)

  identical(url[['scheme']], "https") || is_loopback_host(url[['hostname']])
}


#' Does a redirect address match one an app registered? They must be the
#' same string, except that the port of an address on this computer is
#' ignored: an app there picks a free port each time (RFC 8252, 7.3).
#' @noRd
oauth_redirect_matches <- function (uri, registered) {

  if (uri %in% registered) return (TRUE)

  parts <- function (u) {
    url <- tryCatch(httr2::url_parse(u), error = function (e) NULL)
    if (is.null(url) || !identical(url[['scheme']], "http") || !is_loopback_host(url[['hostname']] %||% "")) return (NULL)
    list(tolower(url[['hostname']]), url[['path']] %||% "/", url[['query']])
  }

  mine <- parts(uri)
  if (is.null(mine)) return (FALSE)

  any(vapply(registered, function (r) identical(parts(r), mine), logical(1)))
}


#' The host of an address, for showing to a person.
#' @noRd
url_host <- function (url) {
  parsed <- tryCatch(httr2::url_parse(url), error = function (e) NULL)
  tolower(parsed[['hostname']] %||% "")
}


#______________________________________________________________________________
#' Check a `client_id` and work out how to fetch its document.
#'
#' The address must be https and have a path, and its host must resolve to
#' public addresses only: the server fetches an address a stranger chose,
#' and must not be made to call computers inside its own network.
#'
#' @return `list(url, resolve)`, where `resolve` pins the connection to one
#'         of the addresses that were checked. Stops with a 400 otherwise.
#' @noRd
oauth_client_target <- function (client_id) {

  refuse <- function (why) stop_user("This app cannot connect: its client_id ", why, ".")

  if (!is_scalar_character(client_id) || is.na(client_id) || nchar(client_id) > 300L ||
      !grepl("^https://[A-Za-z0-9._~:/?@!$&()*+,;=%\\[\\]-]+$", client_id, perl = TRUE))
    refuse("must be an https address")

  url <- tryCatch(httr2::url_parse(client_id), error = function (e) NULL)

  if (is.null(url) || is.null(url[['hostname']]))                 refuse("is not a valid address")
  if (!is.null(url[['username']]) || !is.null(url[['fragment']])) refuse("has a user name or a fragment")
  if (is.null(url[['path']]) || url[['path']] %in% c("", "/"))    refuse("has no path")

  # Looked for in the address as it was given: parsing resolves them away.
  if (grepl("/\\.{1,2}(/|[?]|$)", client_id))                      refuse("has a path with dot segments")

  host      <- url[['hostname']]
  addresses <- host_addresses(host)

  if (length(addresses) == 0)                                 refuse("names a host that cannot be found")
  if (!all(vapply(addresses, is_public_address, logical(1)))) refuse("names a host that is not on the public internet")

  port    <- as.integer(url[['port']] %||% 443L)
  address <- addresses[[1]]
  if (grepl(":", address, fixed = TRUE)) address <- paste0("[", address, "]")

  list(url = client_id, resolve = sprintf("%s:%i:%s", gsub("^\\[|\\]$", "", host), port, address))
}


#' Read a Client ID Metadata Document that has been fetched.
#' @param body  The document, as text.
#' @return `list(client_id, name, redirect_uris)`. Stops with a 400 if the
#'         document cannot be used.
#' @noRd
oauth_client_read <- function (client_id, body) {

  refuse <- function (why) stop_user("This app cannot connect: its client metadata document ", why, ".")

  doc <- tryCatch(fromJSON(body, simplifyVector = FALSE), error = function (e) NULL)

  if (!is.list(doc) || is.null(names(doc)))      refuse("is not a JSON object")
  if (!identical(doc[['client_id']], client_id)) refuse("names a different client_id")

  name <- doc[['client_name']]
  if (!is_scalar_character(name) || is.na(name)) refuse("has no client_name")
  name <- substr(trimws(gsub("[[:cntrl:]]+", " ", name)), 1L, 80L)
  if (!nzchar(name))                             refuse("has no client_name")

  uris <- doc[['redirect_uris']]
  if (!is.list(uris) || length(uris) == 0 || length(uris) > 20L || !all(vapply(uris, is_scalar_character, logical(1))))
    refuse("has no list of redirect_uris")
  uris <- unlist(uris)

  # Apps are public clients here: they prove who they are with PKCE alone.
  method <- doc[['token_endpoint_auth_method']] %||% "none"
  if (!identical(method, "none"))
    refuse("asks for a way of authenticating that this server does not offer (only \"none\")")

  list(client_id = client_id, name = name, redirect_uris = uris)
}


#' Fetch an app's Client ID Metadata Document.
#'
#' Nothing is followed: a redirect is a failure. The request is made in the
#' background, so a slow host holds up only the person connecting.
#' @return A promise of `list(client_id, name, redirect_uris)`.
#' @noRd
oauth_client_fetch <- function (client_id) {

  target <- oauth_client_target(client_id)

  req <- httr2::request(target[['url']])
  req <- httr2::req_timeout(req, oauth_client_timeout)
  req <- httr2::req_headers(req, Accept = "application/json")
  req <- httr2::req_options(req, followlocation = FALSE, maxfilesize = oauth_client_bytes, resolve = target[['resolve']])
  req <- httr2::req_error(req, is_error = function (resp) FALSE)

  unreachable <- function (why) stop_http(
    502L, "This app cannot connect: its client metadata document could not be fetched.", detail = why)

  promises::then(
    promise     = httr2::req_perform_promise(req),
    onRejected  = function (e) unreachable(conditionMessage(e)),
    onFulfilled = function (resp) {

      if (httr2::resp_status(resp) != 200L)
        unreachable(paste("HTTP", httr2::resp_status(resp)))

      body <- tryCatch(httr2::resp_body_raw(resp), error = function (e) raw(0))
      if (length(body) == 0 || length(body) > oauth_client_bytes)
        unreachable("empty or too large")

      text <- rawToChar(body)
      if (!validUTF8(text)) unreachable("not UTF-8")
      Encoding(text) <- "UTF-8"

      oauth_client_read(client_id, text)
    })
}


#______________________________________________________________________________
# The authorization endpoint and the approval page.
#______________________________________________________________________________


#' The person at the browser, if they are signed in: the user of the auth
#' cookie, unless that is a guest.
#' @return `list(user_id, full_name)` or `NULL`.
#' @noRd
browser_account <- function (REQ) {

  token <- auth_token_find(REQ[['DB']], REQ[['CLIENT']][['auth_token']])
  if (is.null(token) || !isFALSE(token[['is_guest']])) return (NULL)

  sql  <- "SELECT full_name FROM users WHERE user_id = ?"
  name <- db_query(REQ[['DB']], sql, "BAcc1", list(token[['user_id']]))

  list(user_id = as.integer(token[['user_id']]), full_name = as.character(name %||% "Unnamed user"))
}


#' A page of plain HTML for a person to read, in the app's own style. It
#' loads nothing but the style sheet, runs no script, and cannot be shown
#' inside another site's page.
#'
#' @param body         HTML, with everything that is not fixed text escaped.
#' @param form_action  Another origin a form on the page may end up at, for
#'                     the approval page's return to the app. (Browsers
#'                     apply `form-action` to the redirect that answers a
#'                     form, too.)
#' @noRd
plain_page <- function (body, status = 200L, form_action = NULL) {

  policy <- paste(
    "default-src 'none'",
    "style-src 'self'",
    "img-src 'self'",
    "font-src 'self'",
    paste(c("form-action 'self'", form_action), collapse = " "),
    "base-uri 'none'",
    "frame-ancestors 'none'",
    sep = "; " )

  response(
    status  = status,
    body    = paste0(
      '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>ATIMA</title>',
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
      '<link rel="stylesheet" href="/www/css/app.css"></head><body class="plain">',
      '<main class="page narrow">', body, '</main></body></html>' ),
    headers = list(
      'Content-Type'            = "text/html; charset=utf-8",
      'Cache-Control'           = "no-store",
      'Content-Security-Policy' = policy,
      # Not "no-referrer": with that, a browser sends a form from this page
      # with `Origin: null`, and `check_origin()` takes it for another
      # site's. The page's address still goes to no other site.
      'Referrer-Policy'         = "same-origin",
      'X-Content-Type-Options'  = "nosniff",
      'X-Frame-Options'         = "DENY" ))
}


#' The redirect that returns the browser to an app.
#' @param params  What to add to the address: `code`, or `error`; `state`
#'                and `iss` are added here.
#' @noRd
oauth_return <- function (REQ, entry, params) {

  params <- c(params, if (!is.null(entry[['state']])) list(state = entry[['state']]), list(iss = oauth_issuer(REQ[['CONFIG']])))
  query  <- paste0(names(params), "=", vapply(params, utils::URLencode, character(1), reserved = TRUE), collapse = "&")
  uri    <- entry[['redirect_uri']]

  response(
    status = 303L,
    header(Location = paste0(uri, if (grepl("?", uri, fixed = TRUE)) "&" else "?", query)),
    header('Cache-Control' = "no-store"),
    header('Referrer-Policy' = "no-referrer") )
}


#______________________________________________________________________________
#' `GET /oauth/authorize`: an app has sent a person's browser here to be
#' let in.
#'
#' Called twice for one authorization when the person has to sign in first:
#' by the app, with the OAuth parameters, and then by `/auth/callback`,
#' with `request`, the name under which those parameters were kept.
#'
#' Nothing is ever sent back to `redirect_uri` until the app's document has
#' been fetched and names that address: until then every failure is a page
#' for the person.
#'
#' @return The approval page; or a redirect to the sign-in; or, when the
#'         app's document has to be fetched first, a wait that ends in one
#'         of those.
#' @noRd
oauth_authorize <- function (
    REQ, response_type = NULL, client_id = NULL, redirect_uri = NULL, code_challenge = NULL,
    code_challenge_method = NULL, state = NULL, scope = NULL, resource = NULL, request = NULL ) {

  oauth    <- REQ[['AUTH']][['oauth']]
  requests <- oauth[['requests']]

  if (!is.null(request)) {
    entry <- oauth_take(requests, request, oauth_pending_ttl, keep = TRUE)
    if (is.null(entry))
      stop_user("This request to connect an app has expired. Please start again from the app.")
    return (oauth_approval(REQ, request, entry))
  }

  if (is.null(client_id) || is.null(redirect_uri))
    stop_user("This is where AI apps send people to connect to ATIMA. The request is missing its client_id or redirect_uri.")

  if (!oauth_redirect_valid(redirect_uri))
    stop_user("This app cannot connect: the address it wants to return to must be https, or on this computer.")

  oauth_sweep(requests, oauth_pending_ttl)

  entry <- list(
    created        = Sys.time(),
    client_id      = client_id,
    redirect_uri   = redirect_uri,
    state          = state,
    response_type  = response_type,
    code_challenge = code_challenge,
    method         = code_challenge_method,
    scope          = scope,
    resource       = resource )

  proceed <- function (client) {

    if (!oauth_redirect_matches(redirect_uri, client[['redirect_uris']]))
      stop_user("This app cannot connect: the address it wants to return to is not one it has registered.")

    entry[['client_name']] <- client[['name']]

    # From here on the app can be told what is wrong with its request.
    problem <- oauth_request_problem(REQ, entry)
    if (!is.null(problem))
      return (oauth_return(REQ, entry, problem))

    request <- random_string(43)
    requests[[request]] <- entry

    oauth_approval(REQ, request, entry)
  }

  cached <- oauth_take(oauth[['clients']], client_id, oauth_client_ttl, keep = TRUE)
  if (!is.null(cached)) return (proceed(cached[['client']]))

  # Checked now, so that a bad client_id is refused before anything waits.
  oauth_client_target(client_id)

  waiting(
    start  = function () oauth_client_fetch(client_id),
    finish = function (client) {
      clients <- oauth[['clients']]
      if (length(clients) >= oauth_client_max) rm(list = ls(clients), envir = clients)
      clients[[client_id]] <- list(created = Sys.time(), client = client)
      proceed(client)
    })
}


#' What is wrong with an authorization request, as the parameters to return
#' to the app; `NULL` if nothing is.
#' @noRd
oauth_request_problem <- function (REQ, entry) {

  problem <- function (error, description) list(error = error, error_description = description)

  if (!identical(entry[['response_type']], "code"))
    return (problem("unsupported_response_type", "Only response_type=code is supported."))

  if (!isTRUE(grepl("^[A-Za-z0-9_-]{43}$", entry[['code_challenge']])) || !identical(entry[['method']], "S256"))
    return (problem("invalid_request", "A PKCE code_challenge with code_challenge_method=S256 is required."))

  resource <- entry[['resource']]
  if (!is.null(resource) && !identical(sub("/+$", "", resource), oauth_resource(REQ[['CONFIG']])))
    return (problem("invalid_target", "This server only issues tokens for its own MCP endpoint."))

  asked <- oauth_scope_list(entry[['scope']])
  if (!all(asked %in% c(oauth_scopes, "offline_access")))
    return (problem("invalid_scope", "The scopes are read and write."))

  NULL
}


#' The scopes in a `scope` parameter.
#' @noRd
oauth_scope_list <- function (scope) {
  if (!is_scalar_character(scope) || is.na(scope)) return (character(0))
  parts <- strsplit(trimws(scope), "[[:space:]]+")[[1]]
  parts[nzchar(parts)]
}


#______________________________________________________________________________
#' The approval page, or the way to it.
#'
#' Someone who is not signed in is sent to sign in and comes back here. The
#' page names the app as its own document does, and the host the person
#' will be returned to, which is what they can check for themselves. The
#' form carries a value made for this page view, so that only this page
#' can submit it.
#' @noRd
oauth_approval <- function (REQ, request, entry) {

  user <- browser_account(REQ)

  if (is.null(user)) {
    back <- utils::URLencode(paste0("/oauth/authorize?request=", request), reserved = TRUE)
    return (response(
      status = 302L,
      header(Location = paste0("/auth/login?return_to=", back)),
      header('Cache-Control' = "no-store") ))
  }

  entry[['csrf']]    <- random_string(43)
  entry[['user_id']] <- user[['user_id']]
  REQ[['AUTH']][['oauth']][['requests']][[request]] <- entry

  writes   <- isTRUE(REQ[['CONFIG']][['mcp_writes']])
  redirect <- httr2::url_parse(entry[['redirect_uri']])
  host    <- tolower(redirect[['hostname']])
  local   <- is_loopback_host(host)
  origin  <- paste0(redirect[['scheme']], "://", redirect[['hostname']], if (!is.null(redirect[['port']])) paste0(":", redirect[['port']]))

  choice <- function (value, label, detail, checked) paste0(
    '<label class="consent-choice"><input type="radio" name="access" value="', value, '"', if (checked) ' checked', '>',
    '<span><strong>', label, '</strong><span class="hint">', detail, '</span></span></label>' )

  body <- paste0(
    '<form class="card consent" method="post" action="/oauth/approve">',
    '<h1>Connect an app to ATIMA</h1>',
    '<p><strong>', html_escape(entry[['client_name']]), '</strong> (', html_escape(url_host(entry[['client_id']])), ') ',
    'wants to use ATIMA as <strong>', html_escape(user[['full_name']]), '</strong>.</p>',
    '<p>If you connect it, you will be returned to: <strong>',
    if (local) 'an app on this computer' else html_escape(host), '</strong></p>',
    if (local) paste0(
      '<p class="hint problem">Any program on this computer could be asking under this name. ',
      'Connect only if you started this yourself, just now, from the app.</p>' ),
    '<fieldset><legend>What may it do?</legend>',
    # Reading is what is chosen unless the person chooses otherwise,
    # whatever the app asked for: apps ask for everything a server offers.
    choice("read", "See your projects and run analyses",
      "It can list and describe the projects you can open, run statistics, draw figures and export data.",
      TRUE),
    if (writes) choice("write", "Also upload, change, share, publish and delete your projects",
      "Everything above, and it can act on your projects as you can. Every change it makes is listed under Connected apps.",
      FALSE),
    '</fieldset>',
    '<p class="hint">What the app reads is passed to the company that provides it, under that company\'s terms. ',
    'It stays connected until it has not been used for ', REQ[['CONFIG']][['app_ttl']] %/% 86400, ' days, ',
    'or until you disconnect it under Connected apps in your account menu.</p>',
    '<input type="hidden" name="request" value="', html_escape(request), '">',
    '<input type="hidden" name="csrf" value="', html_escape(entry[['csrf']]), '">',
    '<div class="card-actions">',
    '<button class="btn" type="submit" name="decision" value="cancel">Cancel</button>',
    '<button class="btn primary" type="submit" name="decision" value="connect">Connect</button>',
    '</div></form>' )

  plain_page(body, form_action = origin)
}


#______________________________________________________________________________
#' `POST /oauth/approve`: the person answered the approval page.
#'
#' The answer counts only if it comes from the browser the page was shown
#' to (the same signed-in user, the value made for that page view), and
#' only once.
#'
#' @param access    `"read"` or `"write"`: what the person chose.
#' @param decision  `"connect"` or `"cancel"`.
#' @return A redirect back to the app, with a code or with `access_denied`.
#' @noRd
oauth_approve <- function (REQ, request, csrf, decision, access = "read") {

  oauth <- REQ[['AUTH']][['oauth']]
  entry <- oauth_take(oauth[['requests']], request, oauth_pending_ttl)
  user  <- browser_account(REQ)

  if (is.null(entry) || is.null(entry[['csrf']]))
    stop_user("This request to connect an app has expired. Please start again from the app.")

  if (is.null(user) || !identical(user[['user_id']], entry[['user_id']]) || !identical(reveal(csrf), entry[['csrf']]))
    stop_forbidden("This page was not sent from the approval page it belongs to. Please start again from the app.")

  if (decision != "connect")
    return (oauth_return(REQ, entry, list(error = "access_denied", error_description = "The person did not approve the connection.")))

  if (access == "write" && !isTRUE(REQ[['CONFIG']][['mcp_writes']]))
    access <- "read"

  codes <- oauth[['codes']]
  oauth_sweep(codes, oauth_code_ttl)

  code <- random_string(48)

  codes[[as.character(sha256(code))]] <- list(
    created        = Sys.time(),
    user_id        = user[['user_id']],
    client_id      = entry[['client_id']],
    client_name    = entry[['client_name']],
    redirect_uri   = entry[['redirect_uri']],
    code_challenge = entry[['code_challenge']],
    scope          = if (access == "write") "read write" else "read" )

  REQ[['SESSION']] <- list(user_id = user[['user_id']])
  log_event("info", "app_approved", user_id = user[['user_id']], app = entry[['client_name']], scope = access)

  oauth_return(REQ, entry, list(code = code))
}


#______________________________________________________________________________
# The token endpoint.
#______________________________________________________________________________


#' A new token of a connection. Only its SHA-256 is kept.
#' @param kind  `"access"` or `"refresh"`.
#' @return The token.
#' @noRd
oauth_token_new <- function (DB, grant_id, kind, ttl) {

  token <- paste0(if (kind == "access") "ata_" else "atr_", random_string(48))

  db_insert(
    DB = DB, table = "app_tokens", err_code = "OTNew1",
    grant_id    = grant_id,
    kind        = kind,
    token_sha   = as.character(sha256(token)),
    expires_utc = sql_time(Sys.time() + ttl) )

  token
}


#' The answer of the token endpoint: a new access token and a new refresh
#' token for a connection, which from now lasts another `app_ttl`.
#' @noRd
oauth_issue <- function (REQ, grant_id, scope) {

  DB  <- REQ[['DB']]
  ttl <- REQ[['CONFIG']][['app_ttl']]

  db_update(DB, "app_grants", grant_id, "OIss1", expires_utc = sql_time(Sys.time() + ttl))

  oauth_json(headers = list(Pragma = "no-cache"), body = list(
    access_token  = oauth_token_new(DB, grant_id, "access", oauth_access_ttl),
    token_type    = "Bearer",
    expires_in    = as.integer(oauth_access_ttl),
    refresh_token = oauth_token_new(DB, grant_id, "refresh", ttl),
    scope         = scope ))
}


#______________________________________________________________________________
#' `POST /oauth/token`: a code, or a refresh token, for new tokens.
#'
#' Refusals are in OAuth's own form, `{"error", "error_description"}`.
#'
#' @param code,code_verifier,refresh_token  Wrapped in `secret()`.
#' @noRd
oauth_token <- function (
    REQ, grant_type = NULL, client_id = NULL, code = NULL, redirect_uri = NULL,
    code_verifier = NULL, refresh_token = NULL, resource = NULL, scope = NULL ) {

  tryCatch(
    oauth_error = function (e) oauth_json(
      status = e[['status']],
      body   = list(error = e[['error']], error_description = conditionMessage(e)) ),
    expr = {

      if (!is.null(resource) && !identical(sub("/+$", "", resource), oauth_resource(REQ[['CONFIG']])))
        stop_oauth("invalid_target", "This server only issues tokens for its own MCP endpoint.")

      if (is.null(client_id))
        stop_oauth("invalid_request", "client_id is required.")

      if (identical(grant_type, "authorization_code")) {
        oauth_token_from_code(REQ, client_id, code, redirect_uri, code_verifier)
      } else if (identical(grant_type, "refresh_token")) {
        oauth_token_from_refresh(REQ, client_id, refresh_token)
      } else {
        stop_oauth("unsupported_grant_type", "The grant types are authorization_code and refresh_token.")
      }
    })
}


#' A code for tokens. A code works once, within a minute, for the app and
#' the redirect address it was made for, and only with the PKCE verifier
#' whose SHA-256 the authorization request carried.
#' @noRd
oauth_token_from_code <- function (REQ, client_id, code, redirect_uri, code_verifier) {

  if (is.null(code) || is.null(code_verifier))
    stop_oauth("invalid_request", "code and code_verifier are required.")

  codes <- REQ[['AUTH']][['oauth']][['codes']]
  entry <- oauth_take(codes, as.character(sha256(reveal(code))), oauth_code_ttl)

  if (is.null(entry))
    stop_oauth("invalid_grant", "The code is unknown, has been used or has expired.")

  if (!identical(entry[['client_id']], client_id))
    stop_oauth("invalid_grant", "The code was issued to a different client.")

  if (!is.null(redirect_uri) && !identical(redirect_uri, entry[['redirect_uri']]))
    stop_oauth("invalid_grant", "redirect_uri is not the one the code was issued for.")

  verifier <- reveal(code_verifier)
  if (!grepl("^[A-Za-z0-9._~-]{43,128}$", verifier) ||
      !identical(jose::base64url_encode(sha256(charToRaw(verifier))), entry[['code_challenge']]))
    stop_oauth("invalid_grant", "code_verifier does not match the code_challenge.")

  DB <- REQ[['DB']]

  sql <- "SELECT is_guest FROM users WHERE user_id = ?"
  if (!isFALSE(db_query(DB, sql, "OTCode1", list(entry[['user_id']]))))
    stop_oauth("invalid_grant", "The account no longer exists.")

  grant_id <- db_insert(
    DB = DB, table = "app_grants", err_code = "OTCode2",
    user_id       = entry[['user_id']],
    client_id     = entry[['client_id']],
    client_name   = entry[['client_name']],
    redirect_host = url_host(entry[['redirect_uri']]),
    scope         = entry[['scope']],
    resource      = oauth_resource(REQ[['CONFIG']]),
    expires_utc   = sql_time(Sys.time() + REQ[['CONFIG']][['app_ttl']]) )

  REQ[['SESSION']] <- list(user_id = entry[['user_id']])
  log_event("info", "app_connected", user_id = entry[['user_id']], grant_id = grant_id)

  oauth_issue(REQ, grant_id, entry[['scope']])
}


#' A refresh token for new tokens. The token is replaced: the one presented
#' stops working. If it had been replaced already, somebody has a copy, and
#' the connection is ended (unless that happened a moment ago, which is an
#' app refreshing twice at once).
#' @noRd
oauth_token_from_refresh <- function (REQ, client_id, refresh_token) {

  if (is.null(refresh_token))
    stop_oauth("invalid_request", "refresh_token is required.")

  DB  <- REQ[['DB']]
  now <- Sys.time()

  sql <- paste0(
    "SELECT token_id, grant_id, replaced_utc, client_id, scope, user_id",
    " FROM app_tokens JOIN app_grants USING (grant_id)",
    " WHERE token_sha = ? AND kind = 'refresh' AND app_tokens.expires_utc > ? AND app_grants.expires_utc > ?" )
  found <- db_query(DB, sql, "OTRef1", list(as.character(sha256(reveal(refresh_token))), sql_time(now), sql_time(now)))

  refused <- "The refresh token is unknown, has been replaced or has expired."

  if (is.null(found) || !identical(found[['client_id']], client_id))
    stop_oauth("invalid_grant", refused)

  if (!is.na(found[['replaced_utc']])) {

    if (difftime(now, found[['replaced_utc']], units = "secs") > oauth_reuse_grace) {
      db_query(DB, "DELETE FROM app_grants WHERE grant_id = ?", "OTRef2", list(found[['grant_id']]))
      log_event("warn", "app_refresh_reused", user_id = found[['user_id']], grant_id = found[['grant_id']])
    }

    # Not stopped with: the deletion above has to be kept.
    return (oauth_json(status = 400L, body = list(error = "invalid_grant", error_description = refused)))
  }

  db_update(DB, "app_tokens", found[['token_id']], "OTRef3", replaced_utc = sql_time(now))

  REQ[['SESSION']] <- list(user_id = found[['user_id']])

  oauth_issue(REQ, found[['grant_id']], found[['scope']])
}


#______________________________________________________________________________
#' `POST /oauth/revoke`: an app gives up its connection (RFC 7009). Either
#' kind of token ends the whole connection. The answer is the same whether
#' or not the token was known.
#' @noRd
oauth_revoke <- function (REQ, token = NULL, token_type_hint = NULL) {

  if (!is.null(token)) {
    sql      <- "SELECT grant_id FROM app_tokens WHERE token_sha = ?"
    grant_id <- db_query(REQ[['DB']], sql, "ORev1", list(as.character(sha256(reveal(token)))))
    if (!is.null(grant_id)) {
      db_query(REQ[['DB']], "DELETE FROM app_grants WHERE grant_id = ?", "ORev2", list(grant_id))
      log_event("info", "app_disconnected", grant_id = grant_id, by = "app")
    }
  }

  oauth_json(json_object())
}


#______________________________________________________________________________
# The resource server's side: who a request to /mcp comes from.
#______________________________________________________________________________


#' The 401 or 403 that tells an app to get a token, or a better one.
#'
#' @param error        `NULL` when no token was sent; `"invalid_token"`, or
#'                     `"insufficient_scope"` with `status = 403`.
#' @param description  What is wrong with the token.
#' @param scope        The scopes the request needs.
#' @noRd
oauth_challenge <- function (REQ, error = NULL, description = NULL, status = 401L, scope = "read") {

  challenge <- paste0("Bearer ", paste(collapse = ", ", c(
    if (!is.null(error))       sprintf('error="%s"', error),
    if (!is.null(description)) sprintf('error_description="%s"', description),
    sprintf('scope="%s"', scope),
    sprintf('resource_metadata="%s"', oauth_resource_metadata(REQ[['CONFIG']])) )))

  message <- description %||% "Sign in to use this server: an access token is required."

  response(
    body    = mcp_json(list(error = list(message = message))),
    status  = as.integer(status),
    headers = list('WWW-Authenticate' = challenge, 'Cache-Control' = "no-store") )
}


#' The connection behind the bearer token of a request.
#'
#' @param headers  The request's headers, named in lower case.
#' @return `list(user_id, grant_id, scope, app)`, where `scope` is a
#'         character vector; or a response (the 401 to send) if the request
#'         has no token, or one that is unknown, expired, or was issued for
#'         something else.
#' @noRd
oauth_caller <- function (REQ, headers) {

  value <- unname(headers["authorization"])

  if (length(value) != 1 || is.na(value) || !nzchar(value))
    return (oauth_challenge(REQ))

  if (!grepl("^[Bb]earer +[A-Za-z0-9._~+/=-]{1,200}$", value))
    return (oauth_challenge(REQ, "invalid_token", "The Authorization header is not a bearer token."))

  token <- secret(sub("^[Bb]earer +", "", value))
  DB    <- REQ[['DB']]
  now   <- sql_time(Sys.time())

  sql <- paste0(
    "SELECT grant_id, user_id, scope, client_name, resource",
    " FROM app_tokens JOIN app_grants USING (grant_id) JOIN users USING (user_id)",
    " WHERE token_sha = ? AND kind = 'access' AND app_tokens.expires_utc > ? AND app_grants.expires_utc > ?",
    "   AND is_guest = 0" )
  found <- db_query(DB, sql, "OCall1", list(as.character(sha256(reveal(token))), now, now))

  if (is.null(found) || !identical(found[['resource']], oauth_resource(REQ[['CONFIG']])))
    return (oauth_challenge(REQ, "invalid_token", "The access token is unknown or has expired."))

  db_query(DB, "UPDATE app_grants SET used_utc = CURRENT_TIMESTAMP WHERE grant_id = ?", "OCall2", list(found[['grant_id']]))
  db_query(DB, "UPDATE users SET seen_utc = CURRENT_TIMESTAMP WHERE user_id = ?", "OCall3", list(found[['user_id']]))

  list(
    user_id  = as.integer(found[['user_id']]),
    grant_id = as.integer(found[['grant_id']]),
    scope    = oauth_scope_list(found[['scope']]),
    app      = found[['client_name']] )
}
