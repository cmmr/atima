# Authentication modes, auth tokens and the auth cookie.


# auth = "none" -----------------------------------------------------------------

test_that("auth = \"none\" refuses to start on a host other computers can reach", {

  settings <- function (host, ...) auth_settings(auth = "none", host = host, port = 8080L, ...)

  for (host in c("0.0.0.0", "::", "192.168.1.20", "10.0.0.5", "atima.example.org", "127.0.0.1.example.org", "", NA))
    expect_error(settings(host), 'auth = "none"', info = host)

  for (host in c("127.0.0.1", "127.0.0.53", "localhost", "LOCALHOST", "::1", "[::1]")) {
    expect_identical(settings(host)$auth, "none", info = host)
    expect_null(settings(host)$oidc, info = host)
  }

  expect_error(auth_settings(auth = "password", host = "127.0.0.1", port = 8080L), 'must be "none" or "oidc"')
})


test_that("run() stops before it touches anything when auth = \"none\" meets a public host", {

  data_dir <- file.path(withr::local_tempdir(), "never-created")

  expect_error(
    suppressMessages(run(host = "0.0.0.0", data_dir = data_dir, open = FALSE)),
    'auth = "none" has no accounts' )
  expect_false(dir.exists(data_dir))

  # The same through the environment, where a deployment would set it.
  withr::local_envvar(ATIMA_HOST = "0.0.0.0", ATIMA_AUTH = "none")
  expect_error(suppressMessages(run(data_dir = data_dir, open = FALSE)), 'auth = "none" has no accounts')
  expect_false(dir.exists(data_dir))
})


test_that("auth = \"oidc\" needs a client, an issuer and an address", {

  settings <- function (...) {
    args <- utils::modifyList(
      list(auth = "oidc", host = "0.0.0.0", port = 8080L, public_url = "https://atima.example.org",
           issuer = "https://auth.globus.org", client_id = "id", client_secret = "secret"),
      list(...) )
    do.call(auth_settings, args)
  }

  ok <- settings()
  expect_identical(ok$oidc$redirect_uri, "https://atima.example.org/auth/callback")
  expect_identical(ok$oidc$issuer, "https://auth.globus.org")
  expect_null(ok$oidc$admins)

  expect_error(settings(client_id = NULL),     "client id and secret")
  expect_error(settings(client_secret = NULL), "client id and secret")
  expect_error(settings(client_secret = ""),   "client id and secret")
  expect_error(settings(issuer = "http://auth.example.org"), "https")
  expect_error(settings(public_url = NULL), "public_url")
  expect_error(settings(public_url = "http://atima.example.org"), "https")
  expect_error(settings(public_url = "https://atima.example.org/app"), "no path")
  expect_error(settings(forwarded_proto_header = "X Forwarded\r\nProto"), "forwarded_proto_header")

  # A trailing slash is dropped; on this computer the address has a default.
  expect_identical(settings(public_url = "https://atima.example.org/")$public_url, "https://atima.example.org")
  expect_identical(settings(host = "127.0.0.1", public_url = NULL)$oidc$redirect_uri, "http://localhost:8080/auth/callback")

  expect_identical(settings(admins = " sub-1, sub-2 ,,")$oidc$admins, c("sub-1", "sub-2"))
})


test_that("in auth = \"none\" mode every browser is the one owner, with no accounts", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req(auth = "none")
  DB  <- REQ$DB
  app <- test_app(REQ)
  db_seed(DB, REQ$CONFIG)

  first <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  expect_identical(first$status, 200L)
  conf <- response_json(first)$CONF
  expect_identical(conf$auth, "none")
  expect_false(conf$is_guest)
  expect_false(conf$is_admin)

  # A second browser, and one with a made-up cookie, are the same owner.
  second <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  forged <- handle_request(fake_request("POST", "/api/session/init", list(), list(auth_token = random_string(64))), app)
  expect_identical(response_json(second)$CONF$user_id, conf$user_id)
  expect_identical(response_json(forged)$CONF$user_id, conf$user_id)

  owner <- db_query(DB, "SELECT * FROM users", "T1")
  expect_identical(owner$user_id, conf$user_id)
  expect_false(owner$is_guest)

  # There is nothing to sign in to or out of, and nobody to share with.
  session <- session_from(first)
  post    <- function (path, args = list()) handle_request(fake_request("POST", path, args, session), app)

  expect_identical(post("/api/account/sign_out")$status, 404L)
  expect_identical(post("/api/account/details")$status, 404L)
  expect_identical(post("/api/sharing/user_search", list(query = "ada"))$status, 404L)
  expect_identical(post("/api/sharing/update", list(user_id = 1, permissions = "view"))$status, 404L)
  expect_true(handle_request(fake_request("GET", "/auth/login"), app)$status %in% c(400L, 404L))
  expect_true(handle_request(fake_request("GET", "/auth/callback", query = "code=x&state=y"), app)$status %in% c(400L, 404L))

  # Everything else is there.
  expect_identical(post("/api/session/heartbeat")$status, 200L)
  expect_identical(post("/api/tree/create", list(node_id = "#"))$status, 200L)

  # The owner is never cleaned up, however long they stay away, and what
  # they made is still theirs when they come back.
  cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 400 * 86400)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM users", "T2"), 1L)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM collections WHERE user_id = ?", "T3", list(conf$user_id)), 1L)
})


test_that("in auth = \"none\" mode only requests addressed to this computer are answered", {

  REQ <- local_test_req(auth = "none")
  app <- test_app(REQ)
  add_test_project(REQ$DB, is_public = TRUE)

  status <- function (host) {
    req <- fake_request("GET", "/")
    req$HTTP_HOST <- host
    handle_request(req, app)$status
  }

  for (host in c("127.0.0.1:8080", "localhost:8080", "localhost", "[::1]:8080", "127.0.0.1"))
    expect_identical(status(host), 200L, info = host)

  # A page on another site that has pointed its own name at 127.0.0.1.
  for (host in list("evil.example.org:8080", "evil.example.org", "127.0.0.1.evil.example.org", "localhost.evil.example.org:8080", "", NULL))
    expect_identical(status(host), 403L, info = host)

  # A shared server is reached by its own name.
  oidc <- local_test_req()
  req  <- fake_request("GET", "/")
  req$HTTP_HOST <- "atima.example.org"
  expect_identical(handle_request(req, test_app(oidc))$status, 200L)
})


test_that("the local owner takes over what earlier guests and password accounts made", {

  local_fake_biom()
  REQ <- local_test_req(auth = "none")
  DB  <- REQ$DB

  guest   <- add_test_user(DB, "Guest 7", is_guest = TRUE)
  account <- add_test_user(DB, "Ada Lovelace")
  signed  <- add_test_user(DB, "Grace Hopper")
  db_update(DB, "users", signed, "T1", issuer = "https://issuer.test", sub = "sub-grace")

  as_guest   <- add_test_project(DB, guest,   "Made as a guest")$project_id
  as_account <- add_test_project(DB, account, "Made with a password account")$project_id
  as_signed  <- add_test_project(DB, signed,  "From a shared server")$project_id
  folder     <- create_collection(DB, account, NULL, "Ada's folder")

  resp  <- handle_request(fake_request("POST", "/api/session/init", list()), test_app(REQ))
  expect_identical(resp$status, 200L)
  owner <- response_json(resp)$CONF$user_id

  expect_identical(project_access(DB, as_guest, owner),   "editor")
  expect_identical(project_access(DB, as_account, owner), "editor")
  expect_identical(db_query(DB, "SELECT user_id FROM collections WHERE collection_id = ?", "T2", list(folder)), owner)
  expect_length(response_json(resp)$jstree_data$private, 3)

  # The earlier rows are gone; someone with a provider identity is not touched.
  expect_setequal(db_query(DB, "SELECT user_id FROM users", "T3"), c(owner, signed))
  expect_identical(project_access(DB, as_signed, owner),  "none")
  expect_identical(project_access(DB, as_signed, signed), "editor")

  # Nothing is lost to cleanup afterwards.
  cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 400 * 86400)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM projects", "T4"), 3L)
})


test_that("guests left from before an upgrade are kept in auth = \"none\" mode", {

  REQ   <- local_test_req(auth = "none")
  DB    <- REQ$DB
  guest <- add_test_user(DB, "Guest 7", is_guest = TRUE)
  pid   <- add_test_project(DB, guest, "Made before the upgrade")$project_id

  removed <- cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 400 * 86400)
  expect_identical(removed$guests, 0L)
  expect_identical(removed$projects, 0L)
  expect_identical(project_access(DB, pid, guest), "editor")

  # On a shared server the same guest would be forgotten.
  shared <- local_test_req()
  add_test_project(shared$DB, add_test_user(shared$DB, "Guest 7", is_guest = TRUE))
  expect_identical(cleanup_run(shared$DB, shared$CONFIG, now = Sys.time() + 400 * 86400)$guests, 1L)
})


test_that("a POST that another web site made the browser send is refused", {

  local_fake_biom()
  REQ <- local_test_req()
  DB  <- REQ$DB
  add_test_project(DB, is_public = TRUE)

  init <- function (headers = character(0), config = list()) {
    app         <- test_app(REQ)
    app$config  <- utils::modifyList(app$config, config)
    req         <- fake_request("POST", "/api/session/init", list())
    req$HEADERS <- headers
    handle_request(req, app)
  }

  # The browser itself, and tools that say nothing about where they are.
  expect_identical(init()$status, 200L)
  expect_identical(init(c("sec-fetch-site" = "same-origin", origin = "http://127.0.0.1:8080"))$status, 200L)
  expect_identical(init(c("sec-fetch-site" = "none"))$status, 200L)
  expect_identical(init(c(origin = "https://atima.example.org"), list(public_url = "https://atima.example.org"))$status, 200L)

  # A form on another site: no session is made and no cookie is set.
  users <- db_query(DB, "SELECT COUNT(*) FROM users", "T1")
  for (headers in list(
      c("sec-fetch-site" = "cross-site"),
      c("sec-fetch-site" = "same-site"),
      c(origin = "https://evil.example.org"),
      c(origin = "null"),
      c(origin = "http://127.0.0.1:8080.evil.example.org"),
      c("sec-fetch-site" = "same-origin", origin = "https://evil.example.org") )) {
    resp <- init(headers)
    expect_identical(resp$status, 403L, info = paste(names(headers), headers, collapse = " "))
    expect_null(resp$headers[["Set-Cookie"]])
  }
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM users", "T2"), users)

  # Pages are still reachable by a link from anywhere.
  req <- fake_request("GET", "/")
  req$HEADERS <- c("sec-fetch-site" = "cross-site")
  expect_identical(handle_request(req, test_app(REQ))$status, 200L)
})


# Tokens and cookies ------------------------------------------------------------

test_that("an auth token is stored only as a hash, and stops working when it expires", {

  REQ  <- local_test_req()
  DB   <- REQ$DB
  user <- add_test_user(DB, "Ada Lovelace")

  issued <- auth_token_new(DB, user, ttl = 3600)
  expect_match(issued$auth_token, "^[A-Za-z0-9]{64}$")

  stored <- db_query(DB, "SELECT * FROM auth_tokens", "T1")
  expect_identical(stored$auth_token_sha, as.character(openssl::sha256(issued$auth_token)))
  expect_false(grepl(issued$auth_token, paste(unlist(stored), collapse = " "), fixed = TRUE))

  found <- auth_token_find(DB, issued$auth_token)
  expect_identical(found$user_id, user)
  expect_false(found$is_guest)

  for (bad in list(NULL, "", "short", random_string(64), paste0(issued$auth_token, "x"), NA))
    expect_null(auth_token_find(DB, bad))

  # Past its expiry it is not found, and cleanup removes it.
  db_query(DB, "UPDATE auth_tokens SET expires_utc = ?", "T2", list(sql_time(Sys.time() - 1)))
  expect_null(auth_token_find(DB, issued$auth_token))
  expect_identical(cleanup_tokens(DB, Sys.time()), 1L)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM auth_tokens", "T3"), 0L)
})


test_that("a session ends when its token expires or is revoked", {

  REQ  <- local_test_req()
  DB   <- REQ$DB
  app  <- test_app(REQ)
  user <- add_test_user(DB, "Ada Lovelace")
  pid  <- add_test_project(DB, user)$project_id

  beat <- function (session) handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), app)$status

  expired <- add_test_session(DB, user, pid)
  revoked <- add_test_session(DB, user, pid)
  expect_identical(beat(expired), 200L)
  expect_identical(beat(revoked), 200L)

  db_query(
    DB, "UPDATE auth_tokens SET expires_utc = ? WHERE auth_token_sha = ?", "T1",
    list(sql_time(Sys.time() - 1), as.character(openssl::sha256(expired$auth_token))) )
  expect_identical(beat(expired), 401L)
  expect_identical(beat(revoked), 200L)

  auth_token_revoke(DB, auth_token_find(DB, revoked$auth_token)$auth_token_id)
  expect_identical(beat(revoked), 401L)
  expect_false(is.na(db_query(DB, "SELECT logout_utc FROM sessions WHERE session_id = ?", "T2", list(revoked$session_id))))
})


test_that("the auth cookie is HttpOnly, SameSite=Lax, and Secure over HTTPS", {

  local_fake_biom()
  REQ <- local_test_req()
  add_test_project(REQ$DB, is_public = TRUE)

  init <- function (config = list(), headers = character(0)) {
    app        <- test_app(REQ)
    app$config <- utils::modifyList(app$config, config)
    req        <- fake_request("POST", "/api/session/init", list())
    req$HEADERS <- headers
    handle_request(req, app)$headers[["Set-Cookie"]]
  }

  # A guest's cookie lasts as long as a guest is remembered.
  plain <- init()
  expect_match(plain, "^auth_token=[A-Za-z0-9]{64}; Max-Age=[0-9]+; Path=/; SameSite=Lax; HttpOnly$")
  max_age <- as.integer(sub("^.*Max-Age=([0-9]+).*$", "\\1", plain))
  expect_true(max_age > 30 * 86400 - 60 && max_age <= 30 * 86400)

  # Served over HTTPS: Secure.
  expect_match(init(list(public_url = "https://atima.example.org")), "; Secure; HttpOnly$")

  # Behind a proxy, only the header the operator named is believed.
  proxied <- c("x-forwarded-proto" = "https")
  expect_no_match(init(headers = proxied), "Secure")
  expect_match(init(list(forwarded_proto_header = "X-Forwarded-Proto"), proxied), "; Secure; HttpOnly$")
  expect_match(init(list(forwarded_proto_header = "X-Forwarded-Proto"), c("x-forwarded-proto" = "https, http")), "Secure")
  expect_no_match(init(list(forwarded_proto_header = "X-Forwarded-Proto"), c("x-forwarded-proto" = "http")), "Secure")
  expect_no_match(init(list(forwarded_proto_header = "X-Forwarded-Proto"), c("x-forwarded-scheme" = "https")), "Secure")
  expect_no_match(init(list(forwarded_proto_header = "X-Forwarded-Proto")), "Secure")
})


test_that("a returning guest keeps their identity and their cookie is renewed", {

  local_fake_biom()
  REQ <- local_test_req()
  DB  <- REQ$DB
  app <- test_app(REQ)
  add_test_project(DB, is_public = TRUE)

  first <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  guest <- response_json(first)$CONF$user_id

  # Twenty days on, the token is still good; coming back renews it.
  db_query(DB, "UPDATE auth_tokens SET expires_utc = ?", "T1", list(sql_time(Sys.time() + 10 * 86400)))
  again <- handle_request(fake_request("POST", "/api/session/init", list(), session_from(first)), app)
  expect_identical(response_json(again)$CONF$user_id, guest)
  expect_identical(session_from(again)$auth_token, session_from(first)$auth_token)
  expires <- db_query(DB, "SELECT expires_utc FROM auth_tokens", "T2")
  expect_gt(as.numeric(expires), as.numeric(Sys.time()) + 29 * 86400)

  # With an expired cookie, the browser is a new guest.
  db_query(DB, "UPDATE auth_tokens SET expires_utc = ?", "T3", list(sql_time(Sys.time() - 1)))
  later <- handle_request(fake_request("POST", "/api/session/init", list(), session_from(first)), app)
  expect_false(identical(response_json(later)$CONF$user_id, guest))
  expect_false(identical(session_from(later)$auth_token, session_from(first)$auth_token))
})


# Signing in and out ------------------------------------------------------------

test_that("adopt_guest merges a guest's things into the user's", {

  REQ   <- local_test_req()
  DB    <- REQ$DB
  user  <- add_test_user(DB, "Ada Lovelace")
  guest <- add_test_user(DB, "Guest 2", is_guest = TRUE)
  other <- add_test_user(DB, "Grace Hopper")

  folder   <- create_collection(DB, guest, NULL, "Guest folder")
  uploaded <- add_test_project(DB, guest, "Uploaded", collection_id = folder)
  both     <- add_test_project(DB, other, "Shared with both")
  linked   <- add_test_project(DB, other, "Opened by link")
  db_insert(DB, "permissions", "T1", user_id = user,  project_id = both$project_id, is_editor = FALSE)
  db_insert(DB, "permissions", "T2", user_id = guest, project_id = both$project_id, is_editor = TRUE)
  db_insert(DB, "permissions", "T3", user_id = guest, project_id = linked$project_id, is_editor = FALSE)
  db_insert(DB, "last_access", "T4", user_id = guest, project_id = uploaded$project_id)

  adopt_guest(DB, guest, user)

  expect_null(db_query(DB, "SELECT user_id FROM users WHERE user_id = ?", "T5", list(guest)))
  expect_identical(project_access(DB, uploaded$project_id, user), "editor")
  expect_identical(project_access(DB, linked$project_id, user),   "viewer")
  expect_identical(project_access(DB, both$project_id, user),     "editor")
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM permissions WHERE user_id = ?", "T6", list(user)), 3L)
  expect_identical(db_query(DB, "SELECT user_id FROM collections", "T7"), user)
  expect_identical(db_query(DB, "SELECT user_id FROM last_access", "T8"), user)

  # The upload still sits in the folder it was put in.
  expect_identical(
    db_query(DB, "SELECT collection_id FROM permissions WHERE user_id = ? AND project_id = ?", "T9", list(user, uploaded$project_id)),
    folder )

  # Nothing of the user's is ever given away to a non-guest.
  adopt_guest(DB, other, user)
  expect_identical(project_access(DB, linked$project_id, other), "editor")

  # After cleanup, nothing the guest uploaded has been lost.
  cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 400 * 86400)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM projects", "T10"), 3L)
})


test_that("signing out revokes the cookie in every tab and removes it from the browser", {

  local_fake_biom()
  REQ  <- local_test_req()
  DB   <- REQ$DB
  app  <- test_app(REQ)
  user <- add_test_user(DB, "Ada Lovelace")
  pid  <- add_test_project(DB, user)$project_id

  tab1 <- add_test_session(DB, user, pid)
  tab2 <- tab1
  tab2$session_key <- "2secondtab"
  db_insert(
    DB, "sessions", "T1", user_id = user, draft_id = create_draft(DB, pid), ip_address = "127.0.0.1",
    session_key = tab2$session_key, auth_token_id = auth_token_find(DB, tab1$auth_token)$auth_token_id )

  elsewhere <- add_test_session(DB, user, pid)

  post <- function (session, path) handle_request(fake_request("POST", path, list(), session), app)
  expect_identical(post(tab2, "/api/session/heartbeat")$status, 200L)

  resp <- post(tab1, "/api/account/sign_out")
  expect_identical(resp$status, 200L)
  expect_match(resp$headers[["Set-Cookie"]], "^auth_token=deleted; Max-Age=0; Path=/; SameSite=Lax; HttpOnly$")

  expect_identical(post(tab1, "/api/session/heartbeat")$status, 401L)
  expect_identical(post(tab2, "/api/session/heartbeat")$status, 401L)
  expect_null(auth_token_find(DB, tab1$auth_token))

  # Another browser of the same user is not signed out, and the user and
  # their projects are untouched.
  expect_identical(post(elsewhere, "/api/session/heartbeat")$status, 200L)
  expect_identical(project_access(DB, pid, user), "editor")

  # The signed-out browser starts again as a guest.
  add_test_project(DB, is_public = TRUE)
  init <- handle_request(fake_request("POST", "/api/session/init", list(), tab1), app)
  expect_true(response_json(init)$CONF$is_guest)

  # Signing out needs the tab's session key, so another site cannot do it.
  expect_identical(post(list(auth_token = elsewhere$auth_token), "/api/account/sign_out")$status, 401L)
  expect_identical(post(elsewhere, "/api/session/heartbeat")$status, 200L)
})


test_that("the account route shows a signed-in user their own details only", {

  REQ  <- local_test_req()
  DB   <- REQ$DB
  app  <- test_app(REQ)
  user <- add_test_user(DB, "Ada Lovelace")
  db_update(DB, "users", user, "T1", email = "ada@example.org", issuer = "https://issuer.test", sub = "sub-ada")
  guest <- add_test_user(DB, "Guest 2", is_guest = TRUE)
  pid   <- add_test_project(DB, is_public = TRUE)$project_id

  post <- function (user_id) handle_request(fake_request("POST", "/api/account/details", list(), add_test_session(DB, user_id, pid)), app)

  expect_identical(
    response_json(post(user)),
    list(full_name = "Ada Lovelace", affiliation = NULL, email = "ada@example.org", issuer = "https://issuer.test") )

  expect_identical(post(guest)$status, 403L)
})


test_that("nothing password-related is left in the package", {

  ns <- asNamespace("atima")

  gone <- c(
    "api_create_account", "api_update_account", "api_reset_password", "api_sign_in", "api_log_out",
    "authenticate_password", "send_email", "sanity_check" )
  expect_false(any(vapply(gone, exists, NA, envir = ns, inherits = FALSE)))

  imports <- names(getNamespaceImports(ns))
  expect_false(any(c("sodium", "blastula") %in% imports))

  paths <- vapply(route_table(), function (r) r$path, character(1))
  expect_false(any(grepl("password|sign_in|account/create|account/update", paths)))
})
