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
