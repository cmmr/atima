#______________________________________________________________________________
# Signing in with OpenID Connect.
#
# atima is a confidential client of one provider, set by `run()`'s
# `oidc_issuer`, `oidc_client_id` and `oidc_client_secret`. Everything else
# is read from the provider's discovery document. The flow is the
# authorization code flow with PKCE:
#
#   GET /auth/login      Make a `state`, a `nonce` and a PKCE verifier, keep
#                        them in memory for ten minutes, tie them to this
#                        browser with a cookie, and send the browser to the
#                        provider.
#   GET /auth/callback   The provider sends the browser back with a code.
#                        Check the `state` and the cookie, exchange the code
#                        for an ID token at the provider's token endpoint,
#                        validate the token (`oidc_validate_id_token()`),
#                        and sign the user in (`sign_in()` in `R/auth.R`).
#
# The JWT signature check is done by the 'jose' package and HTTP by 'httr2'.
# The calls to the provider are made by the main process and block it for
# as long as the provider takes to answer (at most `oidc_timeout` seconds).
#______________________________________________________________________________


# Seconds to wait for the provider, and to keep an unfinished sign-in.
oidc_timeout     <- 10
oidc_pending_ttl <- 600
oidc_pending_max <- 5000L

# Signature algorithms atima accepts, if the provider lists them. Never
# "none", and never a symmetric one.
oidc_algs <- c("RS256", "RS384", "RS512", "ES256", "ES384", "ES512")

# Seconds of clock difference to allow between atima and the provider.
oidc_leeway <- 60


#______________________________________________________________________________
#' Stop because a sign-in failed. The user sees a general message; the
#' reason goes to the log.
#' @noRd
stop_signin <- function (reason, status = 400L) {
  stop_http(status, "Sign-in could not be completed. Please try again.", detail = reason)
}


#______________________________________________________________________________
#' GET a JSON document from the provider.
#' @noRd
oidc_get_json <- function (url, bearer = NULL) {

  req <- httr2::request(url)
  req <- httr2::req_timeout(req, oidc_timeout)
  req <- httr2::req_headers(req, Accept = "application/json")
  if (!is.null(bearer)) req <- httr2::req_auth_bearer_token(req, bearer)

  resp <- httr2::req_perform(req)
  httr2::resp_body_json(resp, check_type = FALSE)
}


#______________________________________________________________________________
#' May atima talk to this URL? Provider endpoints must use HTTPS; plain
#' HTTP is accepted only for a provider on this computer (a test issuer).
#' @noRd
oidc_url_ok <- function (url) {
  if (!is_scalar_character(url) || is.na(url)) return (FALSE)
  if (startsWith(url, "https://")) return (TRUE)
  host <- sub("^http://([^/]*).*$", "\\1", url)
  startsWith(url, "http://") && is_loopback_host(host_name(host))
}


#______________________________________________________________________________
#' Read a provider's discovery document.
#'
#' @param issuer  The issuer URL, exactly as the provider states it.
#' @return A list: `issuer`, the endpoints, `algs` (the signature algorithms
#'         to accept), `scope` (what to ask for), `auth_method` (how to
#'         send the client secret) and an environment for the key cache.
#' @noRd
oidc_discover <- function (issuer) {

  if (!oidc_url_ok(issuer))
    stop("The OpenID Connect issuer must be an https:// URL: ", issuer, call. = FALSE)

  url <- paste0(sub("/+$", "", issuer), "/.well-known/openid-configuration")
  doc <- oidc_get_json(url)

  if (!identical(doc[['issuer']], issuer))
    stop(call. = FALSE, sprintf(
      "The provider at %s says its issuer is '%s', not '%s'. Set oidc_issuer to the value the provider states.",
      url, as.character(doc[['issuer']] %||% ""), issuer ))

  endpoints <- c("authorization_endpoint", "token_endpoint", "jwks_uri")
  for (key in endpoints)
    if (!oidc_url_ok(doc[[key]]))
      stop("The provider's discovery document has no usable ", key, ".", call. = FALSE)

  userinfo <- doc[['userinfo_endpoint']]
  if (!oidc_url_ok(userinfo)) userinfo <- NULL

  algs <- intersect(oidc_algs, unlist(doc[['id_token_signing_alg_values_supported']]) %||% "RS256")
  if (length(algs) == 0)
    stop("The provider signs ID tokens with an algorithm atima does not accept.", call. = FALSE)

  # Ask for the profile and email scopes where the provider has them.
  # (ORCID, for one, only knows "openid".)
  wanted    <- c("openid", "profile", "email")
  supported <- unlist(doc[['scopes_supported']])
  scope     <- if (is.null(supported)) wanted else union("openid", intersect(wanted, supported))

  # The default way to send the client secret is HTTP Basic.
  methods     <- unlist(doc[['token_endpoint_auth_methods_supported']]) %||% "client_secret_basic"
  auth_method <- if ("client_secret_basic" %in% methods) "basic" else if ("client_secret_post" %in% methods) "post" else NULL
  if (is.null(auth_method))
    stop("The provider supports neither client_secret_basic nor client_secret_post.", call. = FALSE)

  list(
    issuer                 = issuer,
    authorization_endpoint = doc[['authorization_endpoint']],
    token_endpoint         = doc[['token_endpoint']],
    jwks_uri               = doc[['jwks_uri']],
    userinfo_endpoint      = userinfo,
    algs                   = algs,
    scope                  = paste(scope, collapse = " "),
    auth_method            = auth_method,
    cache                  = as.environment(list(keys = NULL, fetched = as.POSIXct(0))) )
}


#______________________________________________________________________________
#' The provider, discovered on first use and then remembered.
#' @noRd
oidc_provider <- function (auth) {

  if (is.null(auth[['provider']]))
    auth[['provider']] <- tryCatch(
      expr  = oidc_discover(auth[['oidc']][['issuer']]),
      error = function (e) stop_http(
        502L, "The sign-in provider could not be reached. Please try again later.",
        detail = conditionMessage(e) ))

  auth[['provider']]
}


#______________________________________________________________________________
#' The provider's signing keys, as a list of parsed JWKs.
#'
#' @param refresh  Fetch them again, for a key id that is not in the cache
#'                 (providers rotate keys). At most once a minute.
#' @noRd
oidc_keys <- function (provider, refresh = FALSE) {

  cache <- provider[['cache']]
  stale <- difftime(Sys.time(), cache[['fetched']], units = "secs") > 60

  if (is.null(cache[['keys']]) || (refresh && stale)) {
    jwks <- tryCatch(
      expr  = oidc_get_json(provider[['jwks_uri']]),
      error = function (e) stop_signin(paste("Could not fetch the provider's keys:", conditionMessage(e)), 502L) )
    cache[['keys']]    <- jwks[['keys']]
    cache[['fetched']] <- Sys.time()
  }

  cache[['keys']]
}


#______________________________________________________________________________
#' Validate an ID token.
#'
#' Checks, in order: that the token names an accepted signature algorithm;
#' that it is signed by one of the provider's keys; that it was issued by
#' this provider (`iss`), for this client (`aud`, `azp`), has not expired
#' (`exp`), was not issued in the future (`iat`, `nbf`), answers this
#' sign-in (`nonce`), and names a subject (`sub`).
#'
#' @param id_token   The compact JWT.
#' @param keys       A function `(refresh)` that returns the provider's
#'                   JWKs, or the list itself.
#' @param issuer     The provider's issuer.
#' @param client_id  atima's client id at the provider.
#' @param nonce      The nonce this sign-in sent.
#' @param algs       Accepted signature algorithms.
#' @param now        The current time.
#' @return The token's claims. Stops with a 400 otherwise; the reason is in
#'         the condition's `detail`.
#' @noRd
oidc_validate_id_token <- function (
    id_token, keys, issuer, client_id, nonce, algs = oidc_algs, now = Sys.time() ) {

  if (!is_scalar_character(id_token) || is.na(id_token) || !grepl("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", id_token))
    stop_signin("The ID token is not a signed JWT.")

  header <- tryCatch(jose::jwt_split(id_token)[['header']], error = function (e) NULL)
  alg    <- header[['alg']]
  kid    <- header[['kid']]

  if (!is_one_of(alg, intersect(algs, oidc_algs)))
    stop_signin(paste0("The ID token's signature algorithm is not accepted: ", log_truncate(as.character(alg %||% "(none)"), 20L)))

  if (!is.null(kid) && !is_scalar_character(kid))
    stop_signin("The ID token's key id is malformed.")


  #________________________________________________________
  # Signature. Only keys of the right type, and with the
  # token's key id when it has one, are tried.
  #________________________________________________________
  kty <- if (startsWith(alg, "RS")) "RSA" else "EC"

  candidates <- function (jwks) {
    Filter(x = jwks, function (jwk) {
      identical(jwk[['kty']], kty) &&
        (is.null(jwk[['use']]) || identical(jwk[['use']], "sig")) &&
        (is.null(kid) || identical(jwk[['kid']], kid))
    })
  }

  get_keys <- if (is.function(keys)) keys else function (refresh) keys
  jwks     <- candidates(get_keys(FALSE))
  if (length(jwks) == 0) jwks <- candidates(get_keys(TRUE))

  claims <- NULL
  dated  <- NULL

  for (jwk in jwks) {

    result <- tryCatch(
      expr  = unclass(jose::jwt_decode_sig(id_token, jose::read_jwk(jwk))),
      error = function (e) e )

    if (!inherits(result, "error")) { claims <- result; break }

    # jose checks the signature first and the token's dates second, so
    # these two messages mean the signature was good.
    if (grepl("^Token has expired", conditionMessage(result)))         dated <- "The ID token has expired (exp)."
    if (grepl("^Token is not valid before", conditionMessage(result))) dated <- "The ID token is not valid yet (nbf)."
  }

  if (is.null(claims))
    stop_signin(dated %||% "The ID token's signature does not match any of the provider's keys.")


  #________________________________________________________
  # Claims.
  #________________________________________________________
  now    <- as.numeric(now)
  number <- function (x) is.numeric(x) && length(x) == 1 && !is.na(x)

  if (!identical(claims[['iss']], issuer))
    stop_signin("The ID token was issued by someone else (iss).")

  aud <- unlist(claims[['aud']])
  if (!is.character(aud) || !(client_id %in% aud))
    stop_signin("The ID token was issued for a different client (aud).")

  if (length(aud) > 1 && !identical(claims[['azp']], client_id))
    stop_signin("The ID token has several audiences and was not issued to this client (azp).")

  if (!number(claims[['exp']]) || claims[['exp']] <= now - oidc_leeway)
    stop_signin("The ID token has expired (exp).")

  if (!is.null(claims[['iat']]) && (!number(claims[['iat']]) || claims[['iat']] > now + oidc_leeway))
    stop_signin("The ID token was issued in the future (iat).")

  if (!is.null(claims[['nbf']]) && (!number(claims[['nbf']]) || claims[['nbf']] > now + oidc_leeway))
    stop_signin("The ID token is not valid yet (nbf).")

  if (!is_scalar_character(nonce) || !identical(claims[['nonce']], nonce))
    stop_signin("The ID token does not answer this sign-in (nonce).")

  sub <- claims[['sub']]
  if (!is_scalar_character(sub) || is.na(sub) || !nzchar(sub) || nchar(sub) > 255)
    stop_signin("The ID token names no subject (sub).")

  claims
}


#______________________________________________________________________________
#' Exchange an authorization code for tokens.
#' @return The token endpoint's JSON answer.
#' @noRd
oidc_exchange <- function (provider, oidc, code, verifier) {

  form <- list(
    grant_type    = "authorization_code",
    code          = code,
    redirect_uri  = oidc[['redirect_uri']],
    code_verifier = verifier )

  req <- httr2::request(provider[['token_endpoint']])
  req <- httr2::req_timeout(req, oidc_timeout)
  req <- httr2::req_headers(req, Accept = "application/json")
  req <- httr2::req_error(req, is_error = function (resp) FALSE)

  if (provider[['auth_method']] == "basic") {
    req <- httr2::req_auth_basic(req, oidc[['client_id']], oidc[['client_secret']])
  } else {
    form[['client_id']]     <- oidc[['client_id']]
    form[['client_secret']] <- oidc[['client_secret']]
  }

  req <- do.call(httr2::req_body_form, c(list(req), form))

  resp <- tryCatch(
    expr  = httr2::req_perform(req),
    error = function (e) stop_signin(paste("The token request failed:", conditionMessage(e)), 502L) )

  body <- tryCatch(httr2::resp_body_json(resp, check_type = FALSE), error = function (e) list())

  if (httr2::resp_status(resp) != 200L)
    stop_signin(sprintf(
      "The provider refused the code (HTTP %i, %s).",
      httr2::resp_status(resp), log_truncate(as.character(body[['error']] %||% "no error code"), 100L) ))

  body
}


#______________________________________________________________________________
#' Name, email and affiliation from a set of claims.
#'
#' Providers differ: Globus sends `name`, `email` and `organization`; ORCID
#' sends `given_name` and `family_name` and no email.
#' @return `list(full_name, email, affiliation)`; the last two may be `NULL`.
#' @noRd
oidc_profile <- function (claims) {

  text <- function (x, max) {
    if (!is_scalar_character(x) || is.na(x)) return (NULL)
    x <- trimws(gsub("[[:cntrl:]]+", " ", x))
    if (nzchar(x)) substr(x, 1, max) else NULL
  }

  given_family <- paste(c(text(claims[['given_name']], 50L), text(claims[['family_name']], 50L)), collapse = " ")

  email <- text(claims[['email']], 200L)
  if (!is.null(email) && !grepl("^[^@[:space:]]+@[^@[:space:]]+$", email)) email <- NULL

  list(
    full_name   = text(claims[['name']], 100L) %||% text(given_family, 100L) %||%
                  text(claims[['preferred_username']], 100L) %||% "Unnamed user",
    email       = if (!is.null(email)) tolower(email),
    affiliation = text(claims[['organization']], 100L) )
}


#______________________________________________________________________________
#' Fill in what the ID token left out from the provider's userinfo endpoint.
#' Sign-in does not depend on it: if the call fails, the token's own claims
#' are used.
#' @noRd
oidc_with_userinfo <- function (provider, claims, access_token) {

  if (!is.null(claims[['name']]) && !is.null(claims[['email']])) return (claims)
  if (is.null(provider[['userinfo_endpoint']]))                  return (claims)
  if (!is_scalar_character(access_token))                        return (claims)

  info <- tryCatch(oidc_get_json(provider[['userinfo_endpoint']], bearer = access_token), error = function (e) NULL)

  # Userinfo about anyone else must not be used.
  if (!is.list(info) || !identical(info[['sub']], claims[['sub']])) return (claims)

  c(claims, info[setdiff(names(info), names(claims))])
}


#______________________________________________________________________________
#' Where to send the browser after signing in: only a path on this site
#' that is the home page or a project.
#' @noRd
oidc_return_to <- function (return_to) {
  if (isTRUE(grepl("^/[A-Za-z0-9-]{0,40}$", return_to))) return_to else "/"
}


#______________________________________________________________________________
#' Start a sign-in: send the browser to the provider.
#' @return A redirect.
#' @noRd
auth_login <- function (REQ, return_to = "/") {

  auth     <- REQ[['AUTH']]
  oidc     <- auth[['oidc']]
  provider <- oidc_provider(auth)
  pending  <- auth[['pending']]

  # Forget sign-ins that were never finished.
  cutoff <- Sys.time() - oidc_pending_ttl
  for (key in ls(pending))
    if (pending[[key]][['created']] < cutoff) rm(list = key, envir = pending)

  if (length(pending) >= oidc_pending_max)
    stop_http(503L, "Too many people are signing in right now. Please try again in a few minutes.")

  state    <- random_string(43)
  nonce    <- random_string(43)
  verifier <- random_string(64)
  binder   <- random_string(43)

  pending[[state]] <- list(
    created    = Sys.time(),
    nonce      = nonce,
    verifier   = verifier,
    binder_sha = as.character(sha256(binder)),
    return_to  = oidc_return_to(return_to) )

  query <- c(
    response_type         = "code",
    client_id             = oidc[['client_id']],
    redirect_uri          = oidc[['redirect_uri']],
    scope                 = provider[['scope']],
    state                 = state,
    nonce                 = nonce,
    code_challenge        = jose::base64url_encode(sha256(charToRaw(verifier))),
    code_challenge_method = "S256" )

  query    <- paste0(names(query), "=", vapply(query, utils::URLencode, character(1), reserved = TRUE), collapse = "&")
  endpoint <- provider[['authorization_endpoint']]
  location <- paste0(endpoint, if (grepl("?", endpoint, fixed = TRUE)) "&" else "?", query)

  response(
    status = 302L,
    header(Location = location),
    header('Cache-Control' = "no-store"),
    oidc_login_cookie(REQ, binder) )
}


#' The cookie that ties an unfinished sign-in to the browser that began it.
#' @noRd
oidc_login_cookie <- function (REQ, binder) {
  cookie(
    name      = "oidc_login",
    value     = binder %||% "deleted",
    max_age   = if (is.null(binder)) 0L else as.integer(oidc_pending_ttl),
    path      = "/auth",
    same_site = "Lax",
    secure    = isTRUE(REQ[['CLIENT']][['https']]),
    http_only = TRUE )
}


#______________________________________________________________________________
#' Finish a sign-in: the provider has sent the browser back.
#'
#' @param code   The authorization code.
#' @param state  The `state` that `auth_login()` sent.
#' @param error,error_description  Sent instead of a code when the provider
#'               or the user refused.
#' @return A redirect to the page the user came from, with the new auth
#'         cookie.
#' @noRd
auth_callback <- function (REQ, code = NULL, state = NULL, error = NULL, error_description = NULL) {

  auth     <- REQ[['AUTH']]
  oidc     <- auth[['oidc']]
  pending  <- auth[['pending']]


  #________________________________________________________
  # The `state` must be one this server made, not used
  # before, not too old, and made for this browser.
  #________________________________________________________
  entry <- NULL
  if (isTRUE(grepl("^[A-Za-z0-9]{43}$", state)) && exists(state, envir = pending, inherits = FALSE)) {
    entry <- pending[[state]]
    rm(list = state, envir = pending)
  }

  if (is.null(entry) || entry[['created']] < Sys.time() - oidc_pending_ttl)
    stop_signin("Unknown, reused or expired state.")

  binder <- REQ[['CLIENT']][['oidc_login']]
  if (is.null(binder) || !identical(as.character(sha256(binder)), entry[['binder_sha']]))
    stop_signin("The sign-in was not started by this browser.")

  if (isTRUE(nzchar(error)))
    stop_signin(paste0("The provider answered with an error: ", log_truncate(error, 100L), " ", log_truncate(error_description %||% "", 300L)))

  if (!isTRUE(nzchar(code)))
    stop_signin("The provider sent no code.")


  #________________________________________________________
  # Code -> ID token -> claims.
  #________________________________________________________
  provider <- oidc_provider(auth)
  tokens   <- oidc_exchange(provider, oidc, code, entry[['verifier']])

  claims <- oidc_validate_id_token(
    id_token  = tokens[['id_token']],
    keys      = function (refresh) oidc_keys(provider, refresh),
    issuer    = provider[['issuer']],
    client_id = oidc[['client_id']],
    nonce     = entry[['nonce']],
    algs      = provider[['algs']] )

  claims <- oidc_with_userinfo(provider, claims, tokens[['access_token']])


  #________________________________________________________
  # Sign in.
  #________________________________________________________
  admins <- oidc[['admins']]

  signed <- sign_in(
    REQ      = REQ,
    issuer   = provider[['issuer']],
    sub      = claims[['sub']],
    profile  = oidc_profile(claims),
    is_admin = if (!is.null(admins)) claims[['sub']] %in% admins )

  REQ[['SESSION']] <- list(user_id = signed[['user_id']])
  log_event("info", "sign_in", user_id = signed[['user_id']])

  response(
    status = 302L,
    header(Location = entry[['return_to']]),
    header('Cache-Control' = "no-store"),
    oidc_login_cookie(REQ, NULL),
    auth_cookie(REQ, signed[['auth_token']], REQ[['CONFIG']][['signin_ttl']]) )
}
