# A mock OpenID Connect provider, and a "browser" to sign in through it.
#
# The provider has a discovery document, a JWKS, a token endpoint and a
# userinfo endpoint, and signs ID tokens with an RSA key made for the test.
# It answers atima's HTTP requests through httr2's mocking, so nothing goes
# over the network and no real provider or secret is involved.
#
# Fields a test can change before signing in:
#   identity   the claims about the person (sub, name, email, ...)
#   tamper     function (claims) -> claims, applied before signing
#   sign       function (claims) -> JWT, to sign differently
#   userinfo   the userinfo endpoint's answer, or NULL to answer 500
#   documents  other addresses the mock answers, by URL: what an AI app's
#              Client ID Metadata Document says (see local_mock_app())
local_mock_issuer <- function (
    issuer = test_oidc$issuer, alg = "RS256", auth_method = "client_secret_basic",
    scopes = c("openid", "profile", "email"), env = parent.frame() ) {

  mock <- new.env()

  mock$issuer   <- issuer
  mock$key      <- openssl::rsa_keygen(2048)
  mock$kid      <- "test-key-1"
  mock$requests <- character(0)
  mock$codes    <- list()
  mock$userinfo <- NULL
  mock$documents <- list()
  mock$tamper   <- identity
  mock$identity <- list(sub = "sub-ada", name = "Ada Lovelace", email = "Ada@Example.org", organization = "Analytical Engines")

  mock$jwks <- function () {
    jwk <- jsonlite::fromJSON(jose::write_jwk(mock$key$pubkey))
    list(keys = list(c(jwk, list(kid = mock$kid, use = "sig", alg = alg))))
  }

  mock$sign <- function (claims) {
    claim <- do.call(jose::jwt_claim, claims)
    jose::jwt_encode_sig(claim, mock$key, size = as.integer(substr(alg, 3, 5)), header = list(kid = mock$kid))
  }

  # What the authorization endpoint does: remember what the sign-in asked
  # for and hand out a code.
  mock$authorize <- function (query) {
    code <- paste0("code-", random_string(20))
    mock$codes[[code]] <- query
    code
  }

  url <- function (path) paste0(sub("/+$", "", issuer), path)

  respond <- function (req) {

    path <- sub(sub("/+$", "", issuer), "", httr2::req_get_url(req), fixed = TRUE)
    mock$requests <- c(mock$requests, path)

    # Something else on the web that the test put there: an AI app's
    # Client ID Metadata Document. A list is sent as JSON, a string as it
    # is, a number as that status with no body.
    if (path %in% names(mock$documents)) {
      document <- mock$documents[[path]]
      if (is.numeric(document)) return (httr2::response(status_code = as.integer(document)))
      if (is.list(document))    return (httr2::response_json(body = document))
      return (httr2::response(status_code = 200L, body = charToRaw(document)))
    }

    if (path == "/.well-known/openid-configuration")
      return (httr2::response_json(body = list(
        issuer                                = issuer,
        authorization_endpoint                = url("/authorize"),
        token_endpoint                        = url("/token"),
        userinfo_endpoint                     = url("/userinfo"),
        jwks_uri                              = url("/jwks"),
        scopes_supported                      = as.list(scopes),
        id_token_signing_alg_values_supported = list(alg),
        token_endpoint_auth_methods_supported = list(auth_method) )))

    if (path == "/jwks")
      return (httr2::response_json(body = mock$jwks()))

    if (path == "/userinfo") {
      bearer <- httr2::req_get_headers(req, redacted = "reveal")$Authorization
      if (is.null(mock$userinfo) || !identical(bearer, "Bearer test-access-token"))
        return (httr2::response_json(status_code = 500L, body = list(error = "server_error")))
      return (httr2::response_json(body = mock$userinfo))
    }

    if (path == "/token") {

      form    <- lapply(httr2::req_get_body(req), function (x) utils::URLdecode(as.character(x)))
      headers <- httr2::req_get_headers(req, redacted = "reveal")
      refuse  <- function (error) httr2::response_json(status_code = 400L, body = list(error = error))

      # The client must prove who it is, the way the provider asked.
      basic <- paste0("Basic ", rawToChar(openssl::base64_decode(sub("^Basic ", "", headers$Authorization %||% ""))))
      if (auth_method == "client_secret_basic") {
        if (!identical(basic, paste0("Basic ", test_oidc$client_id, ":", test_oidc$client_secret))) return (refuse("invalid_client"))
      } else {
        if (!is.null(headers$Authorization))                           return (refuse("invalid_client"))
        if (!identical(form$client_id, test_oidc$client_id))           return (refuse("invalid_client"))
        if (!identical(form$client_secret, test_oidc$client_secret))   return (refuse("invalid_client"))
      }

      # A code works once, for the redirect URI and PKCE challenge it was
      # made for.
      asked <- mock$codes[[form$code %||% ""]]
      mock$codes[[form$code %||% ""]] <- NULL

      if (is.null(asked) || !identical(form$grant_type, "authorization_code")) return (refuse("invalid_grant"))
      if (!identical(form$redirect_uri, asked$redirect_uri))                   return (refuse("invalid_grant"))

      challenge <- jose::base64url_encode(openssl::sha256(charToRaw(form$code_verifier %||% "")))
      if (!identical(asked$code_challenge_method, "S256") || !identical(challenge, asked$code_challenge))
        return (refuse("invalid_grant"))

      claims <- c(
        list(iss = issuer, aud = asked$client_id, exp = Sys.time() + 300, iat = Sys.time(), nonce = asked$nonce),
        mock$identity )

      return (httr2::response_json(body = list(
        access_token = "test-access-token",
        token_type   = "Bearer",
        id_token     = mock$sign(mock$tamper(claims)) )))
    }

    httr2::response_json(status_code = 404L, body = list(error = "not_found"))
  }

  httr2::local_mocked_responses(respond, env = env)

  mock
}


# The query parameters of a URL, decoded.
url_query <- function (url) {
  pairs <- strsplit(strsplit(sub("^[^?]*\\?", "", url), "&", fixed = TRUE)[[1]], "=", fixed = TRUE)
  stats::setNames(
    lapply(pairs, function (p) utils::URLdecode(p[[2]])),
    vapply(pairs, function (p) p[[1]], character(1)) )
}

# The cookies a response sets, by name. A removed cookie has Max-Age=0.
set_cookies <- function (resp) {
  headers <- unlist(resp$headers[names(resp$headers) == "Set-Cookie"])
  stats::setNames(as.list(headers), sub("=.*$", "", headers))
}

cookie_value <- function (set_cookie) sub("^[^=]+=([^;]*).*$", "\\1", set_cookie)

# A GET request from a browser that holds the given cookies.
browser_get <- function (path, query = "", cookies = list()) {
  req <- fake_request("GET", path, query = query)
  if (length(cookies) > 0)
    req$HTTP_COOKIE <- paste0(names(cookies), "=", unlist(cookies), collapse = "; ")
  req
}


# The response a request ends in. The callback asks the provider in the
# background, so its answer is a promise; a sign-in refused before that is
# a response at once.
settled <- function (resp) {
  if (!promises::is.promise(resp)) return (resp)
  result <- await(resp)
  if (!is.null(result$error)) stop("handle_request() rejected its promise")
  result$value
}


# Go through a whole sign-in the way a browser would.
#
#   cookies   the cookies the browser holds before it starts (auth_token)
#   between   function (login) run after the browser has been sent to the
#             provider and before it comes back; it may return a changed
#             list(query =, cookies =) for the callback
#
# Returns list(login, callback, cookies): the two responses, and the cookies
# the browser holds at the end.
sign_in_through <- function (app, mock, cookies = list(), return_to = NULL, between = NULL) {

  query <- if (is.null(return_to)) "" else paste0("return_to=", utils::URLencode(return_to, reserved = TRUE))
  login <- handle_request(browser_get("/auth/login", query, cookies), app)

  if (login$status != 302L) return (list(login = login, callback = NULL, cookies = cookies))

  asked   <- url_query(login$headers[["Location"]])
  code    <- mock$authorize(asked)
  cookies <- utils::modifyList(cookies, lapply(set_cookies(login), cookie_value))

  back <- list(query = list(code = code, state = asked$state), cookies = cookies)
  if (!is.null(between)) back <- between(back, asked) %||% back

  query <- paste0(names(back$query), "=", vapply(back$query, utils::URLencode, "", reserved = TRUE), collapse = "&")
  callback <- settled(handle_request(browser_get("/auth/callback", query, back$cookies), app))

  for (name in names(set_cookies(callback))) {
    header <- set_cookies(callback)[[name]]
    cookies[[name]] <- if (grepl("Max-Age=0(;|$)", header)) NULL else cookie_value(header)
  }

  list(login = login, callback = callback, cookies = cookies, asked = asked)
}


# AI apps (R/oauth.R) ----------------------------------------------------------

# An AI app, as the authorization server sees one: a Client ID Metadata
# Document on the mock web, and a host name that resolves to a public
# address. Returns the app's client_id, redirect address and PKCE pair.
local_mock_app <- function (
    mock, client_id = "https://app.test/oauth/client.json", name = "Test App",
    redirect_uri = "https://app.test/callback", env = parent.frame() ) {

  mock$documents[[client_id]] <- list(
    client_id                  = client_id,
    client_name                = name,
    redirect_uris              = list(redirect_uri),
    grant_types                = list("authorization_code", "refresh_token"),
    token_endpoint_auth_method = "none" )

  testthat::local_mocked_bindings(host_addresses = function (host) "93.184.216.34", .env = env)

  verifier <- random_string(64)

  list(
    client_id    = client_id,
    redirect_uri = redirect_uri,
    verifier     = verifier,
    challenge    = jose::base64url_encode(openssl::sha256(charToRaw(verifier))) )
}


# A POST of a form, as a browser or an app sends one.
form_post <- function (path, fields, cookies = list()) {
  body <- paste0(names(fields), "=", vapply(fields, function (v) utils::URLencode(as.character(v), reserved = TRUE), ""), collapse = "&")
  req  <- fake_request("POST", path, charToRaw(body), content_type = "application/x-www-form-urlencoded")
  req$HTTP_HOST <- "localhost:8080"
  if (length(cookies) > 0)
    req$HTTP_COOKIE <- paste0(names(cookies), "=", unlist(cookies), collapse = "; ")
  req
}


# The request with which a browser that holds these cookies opens a tab.
browser_post_init <- function (cookies) {
  req <- fake_request("POST", "/api/session/init", list())
  req$HTTP_HOST <- "localhost:8080"
  if (length(cookies) > 0)
    req$HTTP_COOKIE <- paste0(names(cookies), "=", unlist(cookies), collapse = "; ")
  req
}


# The authorization request an app sends a browser with.
authorize_query <- function (client, ...) {
  query <- utils::modifyList(list(
    response_type         = "code",
    client_id             = client$client_id,
    redirect_uri          = client$redirect_uri,
    code_challenge        = client$challenge,
    code_challenge_method = "S256",
    state                 = "app-state-1",
    resource              = "http://localhost:8080/mcp" ), list(...))
  paste0(names(query), "=", vapply(query, utils::URLencode, "", reserved = TRUE), collapse = "&")
}


# The hidden fields of the approval page.
approval_fields <- function (page) {
  field <- function (name) sub(sprintf('^.*name="%s" value="([^"]*)".*$', name), "\\1", page$body)
  list(request = field("request"), csrf = field("csrf"))
}


# Connect an app the way a person would: the app sends their browser to
# /oauth/authorize, they sign in if they have not, choose what the app may
# do on the approval page, and the app exchanges the code for tokens.
#
#   cookies  the cookies the browser holds before (auth_token of someone
#            signed in, or nothing)
#   access   what the person chooses: "read" or "write"
#
# Returns list(authorize, page, approve, code, token, tokens, cookies): the
# responses on the way, the token endpoint's parsed answer, and the
# browser's cookies at the end.
connect_app <- function (app, mock, client, cookies = list(), access = "read", ...) {

  out <- list(cookies = cookies)

  out$authorize <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client, ...), cookies), app))
  page <- out$authorize

  # Not signed in: off to the provider and back to the approval page.
  if (page$status == 302L && startsWith(page$headers[["Location"]], "/auth/login")) {
    signed      <- sign_in_through(app, mock, cookies, return_to = url_query(page$headers[["Location"]])$return_to)
    out$cookies <- signed$cookies
    back        <- signed$callback$headers[["Location"]]
    page        <- settled(handle_request(browser_get(sub("\\?.*$", "", back), sub("^[^?]*\\?", "", back), out$cookies), app))
  }

  out$page <- page
  if (page$status != 200L) return (out)

  out$approve <- handle_request(form_post("/oauth/approve", c(approval_fields(page), list(decision = "connect", access = access)), out$cookies), app)
  if (out$approve$status != 303L) return (out)

  returned  <- url_query(out$approve$headers[["Location"]])
  out$code  <- returned$code
  out$token <- handle_request(form_post("/oauth/token", list(
    grant_type    = "authorization_code",
    code          = returned$code %||% "",
    client_id     = client$client_id,
    redirect_uri  = client$redirect_uri,
    code_verifier = client$verifier,
    resource      = "http://localhost:8080/mcp" )), app)

  out$tokens <- response_json(out$token)
  out
}


# A connection made directly in the database, for tests that are not about
# connecting. Returns list(grant_id, access_token).
add_test_grant <- function (DB, user_id, scope = "read write", name = "Test App") {

  grant_id <- db_insert(
    DB = DB, table = "app_grants", err_code = "TGrant",
    user_id = user_id, client_id = "https://app.test/oauth/client.json", client_name = name,
    redirect_host = "app.test", scope = scope, resource = "http://localhost:8080/mcp",
    expires_utc = sql_time(Sys.time() + 86400) )

  list(grant_id = as.integer(grant_id), access_token = oauth_token_new(DB, grant_id, "access", 3600))
}


# An MCP request that carries a bearer token, to a server with accounts.
mcp_as <- function (token, method, params = list(), ...) {
  request <- mcp_request(method, params, ...)
  request$HTTP_HOST <- "localhost:8080"
  if (!is.null(token)) request$HEADERS[["authorization"]] <- paste("Bearer", token)
  request
}

# A tool call with a bearer token; returns the JSON-RPC result.
call_as <- function (app, token, name, arguments = json_empty()) {
  resp <- handle_request(mcp_as(token, "tools/call", list(name = name, arguments = arguments)), app)
  if (promises::is.promise(resp)) resp <- await(resp)$value
  body <- response_json(resp)
  if (is.null(body$result)) stop("tools/call failed: ", resp$status, " ", resp$body)
  body$result
}
