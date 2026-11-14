# Signing in with OpenID Connect, against a mock provider (helper-oidc.R).


# A database with one public project to land on, and its app.
local_oidc_app <- function (env = parent.frame()) {
  local_fake_biom(env)
  REQ <- local_test_req(env)
  add_test_project(REQ$DB, is_public = TRUE)
  list(REQ = REQ, DB = REQ$DB, app = test_app(REQ))
}

users <- function (DB) db_query(DB, "SELECT * FROM users ORDER BY user_id", "TU", simplify = FALSE)

# The sign-in was refused: a page saying so, no cookie for a session, and
# nobody was signed in or created.
expect_refused <- function (result, DB, n_users = 0L, status = 400L) {
  resp <- result$callback
  expect_identical(resp$status, status)
  expect_match(resp$headers[["Content-Type"]], "text/html")
  expect_match(resp$body, "Sign-in could not be completed")
  expect_no_match(resp$body, "token|nonce|signature|state")
  expect_null(set_cookies(resp)[["auth_token"]])
  expect_identical(nrow(users(DB)), n_users)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM auth_tokens", "TT"), 0L)
}

# The reason a refused sign-in was logged with.
logged_reason <- function (read_log) {
  errors <- Filter(function (e) e$event == "error", read_log())
  errors[[length(errors)]]$detail
}


# The whole flow ----------------------------------------------------------------

test_that("a guest signs in, keeps their work, and gets a new cookie", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer()

  # A guest with a project and a collection of their own, in a browser.
  guest   <- add_test_user(s$DB, "Guest 1", is_guest = TRUE)
  mine    <- add_test_project(s$DB, guest, "Uploaded as a guest")
  folder  <- create_collection(s$DB, guest, NULL, "My folder")
  session <- add_test_session(s$DB, guest, mine$project_id)

  result <- sign_in_through(s$app, mock, cookies = list(auth_token = session$auth_token), return_to = "/some-project")


  # The browser was sent to the provider with a proper authorization request.
  expect_identical(result$login$status, 302L)
  expect_match(result$login$headers[["Location"]], "^https://issuer.test/authorize\\?")
  asked <- result$asked
  expect_identical(asked$response_type, "code")
  expect_identical(asked$client_id, test_oidc$client_id)
  expect_identical(asked$redirect_uri, test_oidc$redirect_uri)
  expect_identical(asked$scope, "openid profile email")
  expect_identical(asked$code_challenge_method, "S256")
  expect_match(asked$code_challenge, "^[A-Za-z0-9_-]{43}$")
  expect_match(asked$state, "^[A-Za-z0-9]{43}$")
  expect_match(asked$nonce, "^[A-Za-z0-9]{43}$")
  expect_false(identical(asked$state, asked$nonce))
  expect_no_match(result$login$headers[["Location"]], test_oidc$client_secret, fixed = TRUE)

  binder <- set_cookies(result$login)[["oidc_login"]]
  expect_match(binder, "Max-Age=600; Path=/auth; SameSite=Lax; HttpOnly$")


  # It came back signed in, and was sent to where it started.
  resp <- result$callback
  expect_identical(resp$status, 302L)
  expect_identical(resp$headers[["Location"]], "/some-project")
  expect_identical(resp$headers[["Cache-Control"]], "no-store")

  cookie <- set_cookies(resp)[["auth_token"]]
  expect_match(cookie, "^auth_token=[A-Za-z0-9]{64}; Max-Age=2592000; Path=/; SameSite=Lax; HttpOnly$")
  expect_match(set_cookies(resp)[["oidc_login"]], "Max-Age=0")
  expect_false(identical(cookie_value(cookie), session$auth_token))


  # One user, keyed on (issuer, sub), with what the provider said about them.
  all <- users(s$DB)
  expect_identical(nrow(all), 1L)
  expect_identical(all$issuer, "https://issuer.test")
  expect_identical(all$sub, "sub-ada")
  expect_identical(all$full_name, "Ada Lovelace")
  expect_identical(all$email, "ada@example.org")
  expect_identical(all$affiliation, "Analytical Engines")
  expect_false(all$is_guest)
  expect_false(all$is_admin)

  # The guest is gone and everything they had is the user's.
  expect_false(guest %in% all$user_id)
  expect_identical(project_access(s$DB, mine$project_id, all$user_id), "editor")
  expect_identical(db_query(s$DB, "SELECT user_id FROM collections WHERE collection_id = ?", "T1", list(folder)), all$user_id)

  # The guest's cookie and tab no longer work; the new cookie does.
  expect_identical(handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), s$app)$status, 401L)

  init <- handle_request(fake_request("POST", "/api/session/init", list(), list(auth_token = result$cookies$auth_token)), s$app)
  expect_identical(init$status, 200L)
  conf <- response_json(init)$CONF
  expect_identical(conf$user_id, all$user_id)
  expect_identical(conf$full_name, "Ada Lovelace")
  expect_false(conf$is_guest)

  # The unfinished sign-in was forgotten, and the provider was asked for
  # exactly what was needed.
  expect_length(ls(s$REQ$AUTH$pending), 0)
  expect_identical(mock$requests, c("/.well-known/openid-configuration", "/token", "/jwks"))
})


test_that("signing in again finds the same user, and follows the provider's details", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer()

  first <- sign_in_through(s$app, mock)
  expect_identical(first$callback$status, 302L)
  expect_identical(first$callback$headers[["Location"]], "/")

  mock$identity <- list(sub = "sub-ada", name = "Ada King", email = "ada.king@example.org")
  second <- sign_in_through(s$app, mock, cookies = first$cookies)
  expect_identical(second$callback$status, 302L)

  all <- users(s$DB)
  expect_identical(nrow(all), 1L)
  expect_identical(all$full_name, "Ada King")
  expect_identical(all$email, "ada.king@example.org")
  expect_true(is.na(all$affiliation))

  # The first cookie was replaced, not kept alongside.
  expect_false(identical(first$cookies$auth_token, second$cookies$auth_token))
  expect_identical(db_query(s$DB, "SELECT COUNT(*) FROM auth_tokens", "T1"), 1L)
  expect_null(auth_token_find(s$DB, first$cookies$auth_token))
  expect_identical(auth_token_find(s$DB, second$cookies$auth_token)$user_id, all$user_id)

  # Someone else, with the same email address, is someone else.
  mock$identity <- list(sub = "sub-impostor", name = "Ada King", email = "ada.king@example.org")
  third <- sign_in_through(s$app, mock)
  expect_identical(third$callback$status, 302L)
  expect_identical(nrow(users(s$DB)), 2L)
  expect_false(identical(auth_token_find(s$DB, third$cookies$auth_token)$user_id, all$user_id))
})


test_that("a provider like ORCID works: one scope, secret in the body, no email", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer(scopes = "openid", auth_method = "client_secret_post")

  mock$identity <- list(sub = "0000-0002-1825-0097")
  mock$userinfo <- list(sub = "0000-0002-1825-0097", given_name = "Josiah", family_name = "Carberry")

  result <- sign_in_through(s$app, mock)
  expect_identical(result$callback$status, 302L)
  expect_identical(result$asked$scope, "openid")

  all <- users(s$DB)
  expect_identical(all$sub, "0000-0002-1825-0097")
  expect_identical(all$full_name, "Josiah Carberry")
  expect_true(is.na(all$email))
  expect_true("/userinfo" %in% mock$requests)

  # Userinfo that is about somebody else is not used, and a provider whose
  # userinfo endpoint is down still signs people in.
  mock$identity <- list(sub = "0000-0001-5109-3700")
  mock$userinfo <- list(sub = "0000-0002-1825-0097", name = "Josiah Carberry", email = "josiah@example.org")
  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)

  mock$identity <- list(sub = "0000-0003-1415-9269", preferred_username = "pi")
  mock$userinfo <- NULL
  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)

  all <- users(s$DB)
  expect_identical(all$full_name, c("Josiah Carberry", "Unnamed user", "pi"))
  expect_true(all(is.na(all$email)))
})


test_that("a provider that signs with RS512 and wants HTTP Basic, like Globus, works", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer(alg = "RS512")

  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)
  expect_identical(s$REQ$AUTH$provider$algs, "RS512")
  expect_identical(s$REQ$AUTH$provider$auth_method, "basic")
})


# What must be refused ----------------------------------------------------------

test_that("a bad state is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  # A state this server never made.
  result <- sign_in_through(s$app, mock, between = function (back, asked) {
    back$query$state <- random_string(43); back })
  expect_refused(result, s$DB)
  expect_match(logged_reason(read_log), "state")

  # No state at all, or a malformed one.
  for (state in list(NULL, "", "short", "' OR 1=1 --")) {
    result <- sign_in_through(s$app, mock, between = function (back, asked) {
      back$query$state <- state; back })
    expect_refused(result, s$DB)
  }

  # A real state, but in a browser that did not start the sign-in: the
  # attacker's own callback URL, opened by the victim (login CSRF).
  result <- sign_in_through(s$app, mock, between = function (back, asked) {
    back$cookies$oidc_login <- NULL; back })
  expect_refused(result, s$DB)
  expect_match(logged_reason(read_log), "not started by this browser")

  result <- sign_in_through(s$app, mock, between = function (back, asked) {
    back$cookies$oidc_login <- random_string(43); back })
  expect_refused(result, s$DB)

  # A state works once. The second use is refused even with the right cookie.
  kept   <- NULL
  result <- sign_in_through(s$app, mock, between = function (back, asked) { kept <<- back; NULL })
  expect_identical(result$callback$status, 302L)

  kept$query$code <- mock$authorize(result$asked)
  query  <- paste0(names(kept$query), "=", unlist(kept$query), collapse = "&")
  replay <- settled(handle_request(browser_get("/auth/callback", query, kept$cookies), s$app))
  expect_identical(replay$status, 400L)
  expect_null(set_cookies(replay)[["auth_token"]])
  expect_identical(nrow(users(s$DB)), 1L)

  # A state that has grown too old.
  result <- sign_in_through(s$app, mock, between = function (back, asked) {
    entry <- s$REQ$AUTH$pending[[asked$state]]
    entry$created <- Sys.time() - 601
    s$REQ$AUTH$pending[[asked$state]] <- entry
    NULL })
  expect_identical(result$callback$status, 400L)
  expect_identical(nrow(users(s$DB)), 1L)
})


test_that("a bad nonce is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  # A token made for some other sign-in.
  mock$tamper <- function (claims) { claims$nonce <- random_string(43); claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "nonce")

  # A token with no nonce at all.
  mock$tamper <- function (claims) { claims$nonce <- NULL; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "nonce")
})


test_that("a wrong audience is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  # A token the provider issued to another application.
  mock$tamper <- function (claims) { claims$aud <- "some-other-client"; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "aud")

  # Several audiences, and not issued to this client.
  mock$tamper <- function (claims) { claims$aud <- c(test_oidc$client_id, "some-other-client"); claims$azp <- "some-other-client"; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "azp")

  # Several audiences, issued to this client: fine.
  mock$tamper <- function (claims) { claims$aud <- c(test_oidc$client_id, "some-other-client"); claims$azp <- test_oidc$client_id; claims }
  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)
})


test_that("an expired token, or one from the future, is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  mock$tamper <- function (claims) { claims$exp <- Sys.time() - 3600; claims$iat <- Sys.time() - 7200; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "expired")

  mock$tamper <- function (claims) { claims$exp <- NULL; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "expired")

  mock$tamper <- function (claims) { claims$iat <- Sys.time() + 3600; claims$exp <- Sys.time() + 7200; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "future")

  # A clock that is a few seconds off is not a reason to refuse.
  mock$tamper <- function (claims) { claims$exp <- Sys.time() - 5; claims$iat <- Sys.time() + 5; claims }
  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)
})


test_that("a tampered or wrongly signed token is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()
  sign     <- mock$sign

  b64  <- function (x) jose::base64url_encode(charToRaw(as.character(jsonlite::toJSON(x, auto_unbox = TRUE))))
  body <- function (claims) {
    claims$exp <- as.numeric(claims$exp); claims$iat <- as.numeric(claims$iat); claims
  }

  # The payload was changed after signing: same signature, another subject.
  mock$sign <- function (claims) {
    parts    <- strsplit(sign(claims), ".", fixed = TRUE)[[1]]
    payload  <- jsonlite::fromJSON(rawToChar(jose::base64url_decode(parts[[2]])))
    payload$sub <- "sub-someone-else"
    paste(parts[[1]], b64(payload), parts[[3]], sep = ".")
  }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "signature")

  # A signature that was cut short.
  mock$sign <- function (claims) { jwt <- sign(claims); substr(jwt, 1, nchar(jwt) - 8) }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "signature")

  # Signed by a key that is not the provider's, under the provider's key id.
  other <- openssl::rsa_keygen(2048)
  mock$sign <- function (claims) jose::jwt_encode_sig(do.call(jose::jwt_claim, claims), other, header = list(kid = mock$kid))
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "signature")

  # No signature: "alg": "none".
  mock$sign <- function (claims) paste(b64(list(alg = "none", typ = "JWT")), b64(body(claims)), "", sep = ".")
  expect_refused(sign_in_through(s$app, mock), s$DB)
  mock$sign <- function (claims) paste(b64(list(alg = "none", typ = "JWT")), b64(body(claims)), "AAAA", sep = ".")
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "algorithm")

  # A symmetric signature made with the provider's public key as the secret.
  mock$sign <- function (claims) jose::jwt_encode_hmac(
    do.call(jose::jwt_claim, claims), secret = charToRaw(openssl::write_pem(mock$key$pubkey)) )
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "algorithm")

  # An algorithm atima knows, but that this provider does not use.
  mock$sign <- function (claims) jose::jwt_encode_sig(do.call(jose::jwt_claim, claims), mock$key, size = 384, header = list(kid = mock$kid))
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "algorithm")

  # Not a token.
  mock$sign <- function (claims) "not-a-jwt"
  expect_refused(sign_in_through(s$app, mock), s$DB)
})


test_that("a token from another issuer, or with no subject, is refused", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  mock$tamper <- function (claims) { claims$iss <- "https://evil.test"; claims }
  expect_refused(sign_in_through(s$app, mock), s$DB)
  expect_match(logged_reason(read_log), "iss")

  for (sub in list(NULL, "", strrep("x", 300))) {
    mock$tamper <- function (claims) { claims$sub <- sub; claims }
    expect_refused(sign_in_through(s$app, mock), s$DB)
  }
})


test_that("a refusal by the provider, or a code it does not accept, signs nobody in", {

  s        <- local_oidc_app()
  mock     <- local_mock_issuer()
  read_log <- local_log()

  # The person pressed "deny".
  result <- sign_in_through(s$app, mock, between = function (back, asked) {
    back$query <- list(error = "access_denied", error_description = "<script>alert(1)</script>", state = asked$state); back })
  expect_refused(result, s$DB)
  expect_match(logged_reason(read_log), "access_denied")
  expect_no_match(result$callback$body, "<script>", fixed = TRUE)

  # A code that the provider never issued, and no code.
  result <- sign_in_through(s$app, mock, between = function (back, asked) { back$query$code <- "made-up-code"; back })
  expect_refused(result, s$DB)
  expect_match(logged_reason(read_log), "invalid_grant")

  result <- sign_in_through(s$app, mock, between = function (back, asked) { back$query$code <- NULL; back })
  expect_refused(result, s$DB)

  # Nothing about the client secret reaches the page or the log.
  log <- paste(unlist(read_log()), collapse = " ")
  expect_no_match(log, test_oidc$client_secret, fixed = TRUE)
})


test_that("the browser is only ever sent back to a page of this site", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer()

  for (return_to in c("https://evil.test/", "//evil.test", "/\\evil.test", "/a/b", "/x?y=z", "javascript:alert(1)", "")) {
    result <- sign_in_through(s$app, mock, return_to = return_to)
    expect_identical(result$callback$headers[["Location"]], "/", info = return_to)
  }

  expect_identical(sign_in_through(s$app, mock, return_to = "/my-study")$callback$headers[["Location"]], "/my-study")
})


test_that("administrators are the people listed in the configuration", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer()
  is_admin <- function () users(s$DB)$is_admin

  # With no list, the flag in the database stands.
  sign_in_through(s$app, mock)
  expect_false(is_admin())
  db_query(s$DB, "UPDATE users SET is_admin = 1", "T1")
  sign_in_through(s$app, mock)
  expect_true(is_admin())

  # With a list, the list decides, at every sign-in.
  s$REQ$AUTH$oidc$admins <- c("sub-grace")
  sign_in_through(s$app, mock)
  expect_false(is_admin())

  s$REQ$AUTH$oidc$admins <- c("sub-grace", "sub-ada")
  sign_in_through(s$app, mock)
  expect_true(is_admin())
})


test_that("keys the provider has rotated in are fetched, once", {

  s    <- local_oidc_app()
  mock <- local_mock_issuer()

  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)

  # The provider starts signing with a new key.
  mock$key <- openssl::rsa_keygen(2048)
  mock$kid <- "test-key-2"

  # Fetched less than a minute ago: not fetched again, so not accepted yet.
  expect_identical(sign_in_through(s$app, mock)$callback$status, 400L)
  expect_identical(sum(mock$requests == "/jwks"), 1L)

  s$REQ$AUTH$provider$cache$fetched <- Sys.time() - 120
  expect_identical(sign_in_through(s$app, mock)$callback$status, 302L)
  expect_identical(sum(mock$requests == "/jwks"), 2L)
})


test_that("a provider that cannot be found or trusted stops sign-in, not the server", {

  s <- local_oidc_app()

  # Nothing answers.
  httr2::local_mocked_responses(function (req) httr2::response_json(status_code = 503L, body = list()))
  resp <- handle_request(browser_get("/auth/login"), s$app)
  expect_identical(resp$status, 502L)
  expect_match(resp$headers[["Content-Type"]], "text/html")
  expect_match(resp$body, "could not be reached")
  expect_null(s$REQ$AUTH$provider)

  # The rest of the site still works.
  expect_identical(handle_request(fake_request("POST", "/api/session/init", list()), s$app)$status, 200L)
})


test_that("discovery refuses documents that do not belong to the issuer or are not secure", {

  doc <- list(
    issuer                 = "https://issuer.test",
    authorization_endpoint = "https://issuer.test/authorize",
    token_endpoint         = "https://issuer.test/token",
    jwks_uri               = "https://issuer.test/jwks" )

  discover <- function (changes, issuer = "https://issuer.test") {
    httr2::local_mocked_responses(function (req) httr2::response_json(body = utils::modifyList(doc, changes)))
    oidc_discover(issuer)
  }

  provider <- discover(list())
  expect_identical(provider$algs, "RS256")
  expect_identical(provider$auth_method, "basic")
  expect_identical(provider$scope, "openid profile email")
  expect_null(provider$userinfo_endpoint)

  expect_error(discover(list(issuer = "https://evil.test")), "issuer")
  expect_error(discover(list(token_endpoint = "http://issuer.test/token")), "token_endpoint")
  expect_error(discover(list(jwks_uri = NULL)), "jwks_uri")
  expect_error(discover(list(id_token_signing_alg_values_supported = list("HS256", "none"))), "algorithm")
  expect_error(discover(list(token_endpoint_auth_methods_supported = list("private_key_jwt"))), "client_secret")
  expect_error(discover(list(), issuer = "http://issuer.test"), "https")

  # A provider on this computer may use plain HTTP (a test issuer).
  expect_true(oidc_url_ok("http://localhost:9000/realms/test"))
  expect_true(oidc_url_ok("http://127.0.0.1:9000"))
  expect_false(oidc_url_ok("http://localhost.evil.test"))
  expect_false(oidc_url_ok("ftp://issuer.test"))
  expect_false(oidc_url_ok(NULL))
})


# The validation function on its own --------------------------------------------

test_that("oidc_validate_id_token checks each claim", {

  key  <- openssl::rsa_keygen(2048)
  jwks <- list(c(jsonlite::fromJSON(jose::write_jwk(key$pubkey)), list(kid = "k1", use = "sig")))
  now  <- Sys.time()

  token <- function (..., header = list(kid = "k1")) {
    claims <- utils::modifyList(
      list(iss = "https://issuer.test", aud = "client", sub = "sub-1", nonce = "n-1", exp = now + 300, iat = now),
      list(...) )
    jose::jwt_encode_sig(do.call(jose::jwt_claim, claims), key, header = header)
  }

  validate <- function (jwt, keys = jwks, client_id = "client", nonce = "n-1", algs = oidc_algs, at = now) {
    oidc_validate_id_token(jwt, keys, "https://issuer.test", client_id, nonce, algs, at)
  }

  reason <- function (...) expect_error(validate(...), class = "atima_http_error")$detail

  claims <- validate(token())
  expect_identical(claims$sub, "sub-1")

  expect_match(reason(token(iss = "https://issuer.test/")), "iss")
  expect_match(reason(token(aud = "client2")),              "aud")
  expect_match(reason(token(), client_id = "client2"),      "aud")
  expect_match(reason(token(nonce = "n-2")),                "nonce")
  expect_match(reason(token(), nonce = NA_character_),      "nonce")
  expect_match(reason(token(nonce = NULL)),                 "nonce")
  expect_match(reason(token(exp = now - 61)),               "expired")
  expect_match(reason(token(), at = now + 400),             "expired")
  expect_match(reason(token(iat = now + 120)),              "future")
  expect_match(reason(token(nbf = now + 120)),              "not valid yet")
  expect_match(reason(token(sub = NULL)),                   "sub")

  # Keys: the token's key id must be one the provider has, of the right type.
  expect_match(reason(token(header = list(kid = "k2"))), "signature")
  expect_match(reason(token(), keys = list()),           "signature")
  expect_match(reason(token(), keys = list(utils::modifyList(jwks[[1]], list(use = "enc")))), "signature")
  expect_match(reason(token(), algs = "ES256"),          "algorithm")

  # A token with no key id is checked against every key.
  expect_identical(validate(token(header = NULL))$sub, "sub-1")

  # An elliptic-curve key works too.
  ec      <- openssl::ec_keygen("P-256")
  ec_jwks <- list(c(jsonlite::fromJSON(jose::write_jwk(ec$pubkey)), list(kid = "e1")))
  ec_jwt  <- jose::jwt_encode_sig(
    jose::jwt_claim(iss = "https://issuer.test", aud = "client", sub = "sub-2", nonce = "n-1", exp = now + 300),
    ec, header = list(kid = "e1") )
  expect_identical(validate(ec_jwt, keys = ec_jwks)$sub, "sub-2")
  expect_match(reason(ec_jwt), "signature")
})


test_that("oidc_profile takes what it is given and nothing unsafe", {

  expect_identical(
    oidc_profile(list(name = "  Ada\tLovelace ", email = "Ada@Example.ORG", organization = "Engines")),
    list(full_name = "Ada Lovelace", email = "ada@example.org", affiliation = "Engines") )

  expect_identical(oidc_profile(list(given_name = "Ada", family_name = "Lovelace"))$full_name, "Ada Lovelace")
  expect_identical(oidc_profile(list(family_name = "Lovelace"))$full_name, "Lovelace")
  expect_identical(oidc_profile(list(preferred_username = "ada@engines"))$full_name, "ada@engines")
  expect_identical(oidc_profile(list())$full_name, "Unnamed user")

  for (email in list("not an email", "a@b@c", "", 5, c("a@b.c", "d@e.f"), NA_character_))
    expect_null(oidc_profile(list(name = "X", email = email))$email)

  expect_identical(nchar(oidc_profile(list(name = strrep("x", 500)))$full_name), 100L)
  expect_identical(oidc_profile(list(name = list("Ada")))$full_name, "Unnamed user")
})
