# Signing in for AI apps (R/oauth.R): atima as the authorization server for
# its own MCP endpoint, against a mock provider and a mock app
# (helper-oidc.R).


# A server with accounts, one public project, and its app.
local_oauth_app <- function (env = parent.frame()) {
  local_fake_biom(env)
  REQ <- local_test_req(env)
  add_test_project(REQ$DB, is_public = TRUE)
  list(REQ = REQ, DB = REQ$DB, app = test_app(REQ))
}

count <- function (DB, table) db_query(DB, sprintf("SELECT COUNT(*) FROM %s", table), "TCount")

www_authenticate <- function (resp) resp$headers[["WWW-Authenticate"]]


# Finding the way --------------------------------------------------------------

test_that("the metadata documents say where and how an app signs in", {

  s <- local_oauth_app()

  for (path in c("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp")) {
    resp <- handle_request(fake_request("GET", path), s$app)
    doc  <- response_json(resp)
    expect_identical(resp$status, 200L)
    expect_match(resp$headers[["Content-Type"]], "application/json")
    expect_identical(doc$resource, "http://localhost:8080/mcp")
    expect_identical(doc$authorization_servers, list("http://localhost:8080"))
    expect_identical(doc$scopes_supported, list("read", "write"))
    expect_identical(doc$bearer_methods_supported, list("header"))
  }

  resp <- handle_request(fake_request("GET", "/.well-known/oauth-authorization-server"), s$app)
  doc  <- response_json(resp)

  expect_identical(resp$status, 200L)
  # The issuer is exactly what the resource names, and what `iss` will say.
  expect_identical(doc$issuer, "http://localhost:8080")
  expect_identical(doc$authorization_endpoint, "http://localhost:8080/oauth/authorize")
  expect_identical(doc$token_endpoint, "http://localhost:8080/oauth/token")
  expect_identical(doc$revocation_endpoint, "http://localhost:8080/oauth/revoke")
  expect_identical(doc$response_types_supported, list("code"))
  expect_identical(doc$grant_types_supported, list("authorization_code", "refresh_token"))
  # Without these two an app refuses to go on, or falls back to registering.
  expect_identical(doc$code_challenge_methods_supported, list("S256"))
  expect_identical(doc$token_endpoint_auth_methods_supported, list("none"))
  expect_true(doc$client_id_metadata_document_supported)
  expect_true(doc$authorization_response_iss_parameter_supported)
  # Dynamic Client Registration is deprecated and not offered.
  expect_null(doc$registration_endpoint)

  # A server without accounts has none of this: there the same paths are,
  # like any others, a project's address or nothing.
  for (r in route_table())
    if (startsWith(r$handler, "oauth_"))
      expect_identical(r$modes, "oidc", info = r$endpoint)

  local <- local_test_req(auth = "none")
  for (path in c("/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server", "/oauth/authorize"))
    expect_true(handle_request(fake_request("GET", path), test_app(local))$status %in% c(400L, 404L), info = path)
  expect_identical(handle_request(form_post("/oauth/token", list(grant_type = "refresh_token")), test_app(local))$status, 404L)
})


test_that("a request to /mcp without a valid token is told where to sign in", {

  s <- local_oauth_app()

  resp <- handle_request(mcp_as(NULL, "tools/list"), s$app)
  expect_identical(resp$status, 401L)
  expect_identical(
    www_authenticate(resp),
    'Bearer scope="read", resource_metadata="http://localhost:8080/.well-known/oauth-protected-resource/mcp"' )
  expect_null(response_json(resp)$result)

  # Whatever the message is: nothing is said about it, not even that it
  # is malformed, and that goes for the handshake era's opening too.
  for (body in list("{not json", list(jsonrpc = "2.0", id = 1, method = "initialize", params = list(protocolVersion = "2025-11-25")))) {
    request <- mcp_http(body); request$HTTP_HOST <- "localhost:8080"
    expect_identical(handle_request(request, s$app)$status, 401L)
  }

  # A token nobody issued, and things that are not bearer tokens.
  resp <- handle_request(mcp_as(paste0("ata_", random_string(48)), "tools/list"), s$app)
  expect_identical(resp$status, 401L)
  expect_match(www_authenticate(resp), 'error="invalid_token"')

  for (value in c("Basic dXNlcjpwYXNz", "Bearer", "Bearer two words", paste("Bearer", strrep("a", 300)))) {
    request <- mcp_as(NULL, "tools/list")
    request$HEADERS[["authorization"]] <- value
    expect_identical(handle_request(request, s$app)$status, 401L, info = value)
  }

  # A browser's cookie is not looked at here: someone signed in is still
  # nobody to /mcp.
  user    <- add_test_user(s$DB, "Ada Lovelace")
  session <- add_test_session(s$DB, user, add_test_project(s$DB, user)$project_id)
  request <- mcp_as(NULL, "tools/list")
  request$HTTP_COOKIE <- paste0("auth_token=", session$auth_token)
  request$HEADERS[["x-session-key"]] <- session$session_key
  expect_identical(handle_request(request, s$app)$status, 401L)

  # An auth token is not an access token, and the other way round: a
  # bearer token is accepted nowhere but at /mcp.
  expect_identical(handle_request(mcp_as(session$auth_token, "tools/list"), s$app)$status, 401L)

  grant   <- add_test_grant(s$DB, user)
  request <- fake_request("POST", "/api/session/heartbeat", list())
  request$HEADERS <- c(authorization = paste("Bearer", grant$access_token))
  expect_identical(handle_request(request, s$app)$status, 401L)

  request <- fake_request("POST", "/api/apps/list", list())
  request$HEADERS <- c(authorization = paste("Bearer", grant$access_token))
  expect_identical(handle_request(request, s$app)$status, 401L)
})


# The whole flow ----------------------------------------------------------------

test_that("an app is connected for reading, used, refreshed and disconnected", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)
  log    <- local_log()

  out <- connect_app(s$app, mock, client)


  # The app's document was fetched; the person was sent to sign in, and
  # came back to the approval page.
  expect_true(client$client_id %in% mock$requests)
  expect_identical(out$authorize$status, 302L)
  expect_match(out$authorize$headers[["Location"]], "^/auth/login\\?return_to=%2Foauth%2Fauthorize%3Frequest%3D[A-Za-z0-9]{43}$")

  page <- out$page
  expect_identical(page$status, 200L)
  expect_match(page$headers[["Content-Type"]], "text/html")
  expect_identical(page$headers[["X-Frame-Options"]], "DENY")
  expect_identical(page$headers[["Cache-Control"]], "no-store")
  expect_match(page$headers[["Content-Security-Policy"]], "frame-ancestors 'none'")
  expect_match(page$headers[["Content-Security-Policy"]], "form-action 'self' https://app.test", fixed = TRUE)
  expect_false(grepl("script", page$headers[["Content-Security-Policy"]]))
  expect_false(grepl("<script", page$body, fixed = TRUE))

  # It names the app, where the person will be returned to, who they are,
  # and both choices, reading chosen.
  expect_match(page$body, "<strong>Test App</strong> (app.test)", fixed = TRUE)
  expect_match(page$body, "returned to: <strong>app.test</strong>", fixed = TRUE)
  expect_match(page$body, "<strong>Ada Lovelace</strong>", fixed = TRUE)
  expect_match(page$body, 'value="read" checked', fixed = TRUE)
  expect_match(page$body, 'value="write">', fixed = TRUE)
  expect_match(page$body, "See your projects and run analyses", fixed = TRUE)
  expect_match(page$body, "Also upload, change, share, publish and delete your projects", fixed = TRUE)
  expect_match(page$body, "30 days", fixed = TRUE)


  # Approved: back to the app with a code, the app's state, and who issued it.
  expect_identical(out$approve$status, 303L)
  expect_match(out$approve$headers[["Location"]], "^https://app\\.test/callback\\?code=")
  returned <- url_query(out$approve$headers[["Location"]])
  expect_named(returned, c("code", "state", "iss"))
  expect_identical(returned$state, "app-state-1")
  expect_identical(returned$iss, "http://localhost:8080")


  # The code bought an access token and a refresh token, for reading.
  expect_identical(out$token$status, 200L)
  expect_identical(out$token$headers[["Cache-Control"]], "no-store")
  tokens <- out$tokens
  expect_named(tokens, c("access_token", "token_type", "expires_in", "refresh_token", "scope"))
  expect_identical(tokens$token_type, "Bearer")
  expect_identical(tokens$expires_in, 3600L)
  expect_identical(tokens$scope, "read")
  expect_match(tokens$access_token, "^ata_[A-Za-z0-9]{48}$")
  expect_match(tokens$refresh_token, "^atr_[A-Za-z0-9]{48}$")

  # Only their hashes are stored.
  stored <- db_query(s$DB, "SELECT * FROM app_tokens ORDER BY token_id", "T1", simplify = FALSE)
  expect_identical(stored$kind, c("access", "refresh"))
  expect_identical(stored$token_sha, c(as.character(openssl::sha256(tokens$access_token)), as.character(openssl::sha256(tokens$refresh_token))))

  grant <- db_query(s$DB, "SELECT * FROM app_grants", "T2")
  user  <- db_query(s$DB, "SELECT user_id FROM users WHERE sub = 'sub-ada'", "T3")
  expect_identical(grant$user_id, user)
  expect_identical(grant$client_id, client$client_id)
  expect_identical(grant$client_name, "Test App")
  expect_identical(grant$redirect_host, "app.test")
  expect_identical(grant$scope, "read")
  expect_identical(grant$resource, "http://localhost:8080/mcp")
  expect_true(is.na(grant$used_utc))


  # The token works at /mcp. The tool list is the six that read, and says
  # that it is this caller's own.
  resp   <- handle_request(mcp_as(tokens$access_token, "tools/list"), s$app)
  result <- response_json(resp)$result
  expect_identical(resp$status, 200L)
  expect_identical(result$cacheScope, "private")
  expect_identical(
    vapply(result$tools, function (t) t$name, character(1)),
    c("list_projects", "describe_project", "describe_function", "run_stats", "make_plot", "export") )

  expect_identical(response_json(handle_request(mcp_as(tokens$access_token, "server/discover"), s$app))$result$cacheScope, "public")

  # A tool is called as the token's user, and the connection shows its use.
  mine   <- add_test_project(s$DB, user, "Ada's private project")
  listed <- call_as(s$app, tokens$access_token, "list_projects")
  titles <- vapply(listed$structuredContent$projects, function (p) p$title, character(1))
  expect_true("Ada's private project" %in% titles)
  expect_false(is.na(db_query(s$DB, "SELECT used_utc FROM app_grants", "T4")))

  # An app of the handshake era gets in with the same token.
  request <- mcp_http(list(jsonrpc = "2.0", id = 1, method = "initialize", params = list(protocolVersion = "2025-11-25")))
  request$HTTP_HOST <- "localhost:8080"
  request$HEADERS   <- c(authorization = paste("Bearer", tokens$access_token))
  expect_identical(response_json(handle_request(request, s$app))$result$protocolVersion, "2025-11-25")


  # A tool that changes data is not this app's to call: the answer is the
  # one that makes an app ask its user again, and nothing happened.
  resp <- handle_request(mcp_as(tokens$access_token, "tools/call", list(
    name = "delete_project", arguments = list(project = "x", confirm = TRUE) )), s$app)
  expect_identical(resp$status, 403L)
  expect_match(www_authenticate(resp), 'error="insufficient_scope"')
  expect_match(www_authenticate(resp), 'scope="read write"')
  expect_match(www_authenticate(resp), "resource_metadata=")
  expect_identical(count(s$DB, "app_changes"), 0L)


  # Refreshing: new tokens, the refresh token replaced, the connection
  # extended; the old access token works until it runs out.
  refresh <- function (token, client_id = client$client_id) handle_request(form_post("/oauth/token", list(
    grant_type = "refresh_token", refresh_token = token, client_id = client_id )), s$app)

  resp  <- refresh(tokens$refresh_token)
  fresh <- response_json(resp)
  expect_identical(resp$status, 200L)
  expect_identical(fresh$scope, "read")
  expect_false(identical(fresh$access_token, tokens$access_token))
  expect_false(identical(fresh$refresh_token, tokens$refresh_token))
  expect_identical(count(s$DB, "app_grants"), 1L)
  expect_identical(handle_request(mcp_as(fresh$access_token, "tools/list"), s$app)$status, 200L)
  expect_identical(handle_request(mcp_as(tokens$access_token, "tools/list"), s$app)$status, 200L)

  # Another app cannot use this app's refresh token.
  resp <- refresh(fresh$refresh_token, "https://other.test/client.json")
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error, "invalid_grant")


  # The person sees the connection, and ends it. The app is shut out.
  session <- handle_request(browser_post_init(out$cookies), s$app)
  api     <- function (path, args = list()) {
    request <- fake_request("POST", path, args, session_from(session))
    request$HTTP_HOST <- "localhost:8080"
    handle_request(request, s$app)
  }

  apps <- response_json(api("/api/apps/list"))$apps
  expect_length(apps, 1)
  expect_identical(apps[[1]]$name, "Test App")
  expect_identical(apps[[1]]$host, "app.test")
  expect_false(apps[[1]]$writes)
  expect_false(is.null(apps[[1]]$used_utc))

  resp <- api("/api/apps/disconnect", list(grant_id = apps[[1]]$grant_id))
  expect_identical(response_json(resp)$disconnected, 1L)
  expect_identical(count(s$DB, "app_grants"), 0L)
  expect_identical(count(s$DB, "app_tokens"), 0L)
  expect_identical(handle_request(mcp_as(fresh$access_token, "tools/list"), s$app)$status, 401L)
  expect_identical(response_json(refresh(fresh$refresh_token))$error, "invalid_grant")
  expect_length(response_json(api("/api/apps/list"))$apps, 0)


  # Nothing secret was written to the log: no code, no token, no verifier.
  lines <- readLines(getOption("atima.log"))
  for (secret in c(out$code, tokens$access_token, tokens$refresh_token, fresh$access_token, fresh$refresh_token, client$verifier))
    expect_false(any(grepl(secret, lines, fixed = TRUE)))

  events <- vapply(log(), function (e) e$event, character(1))
  expect_true(all(c("app_approved", "app_connected", "app_disconnected") %in% events))
})


test_that("an app approved for changes is offered the tools that change data", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)

  out <- connect_app(s$app, mock, client, access = "write")
  expect_identical(out$tokens$scope, "read write")

  listed <- response_json(handle_request(mcp_as(out$tokens$access_token, "tools/list"), s$app))$result
  expect_identical(vapply(listed$tools, function (t) t$name, character(1)), names(mcp_tool_table()))
  expect_identical(listed$cacheScope, "private")

  apps <- api_apps_list(as.environment(list(DB = s$DB, CONFIG = s$REQ$CONFIG, SESSION = list(
    user_id = db_query(s$DB, "SELECT user_id FROM users WHERE sub = 'sub-ada'", "T1") ))))$apps
  expect_true(as.logical(apps[[1]]$writes))

  # A server whose administrator switched changes off does not offer the
  # choice, and an answer that claims it anyway is taken as reading.
  s$REQ$CONFIG$mcp_writes <- FALSE
  app <- test_app(s$REQ)

  client2 <- local_mock_app(mock, client_id = "https://app.test/oauth/second.json", name = "Second App")
  out     <- connect_app(app, mock, client2, cookies = out$cookies, access = "write")
  expect_false(grepl('value="write"', out$page$body, fixed = TRUE))
  expect_identical(out$tokens$scope, "read")
})


test_that("someone already signed in goes straight to the approval page, and can cancel", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)

  cookies <- sign_in_through(s$app, mock)$cookies
  before  <- length(mock$requests)

  page <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client, scope = "read write"), cookies), s$app))
  expect_identical(page$status, 200L)

  # An app that asked for both still finds reading chosen: changing
  # things is for the person to choose.
  expect_match(page$body, 'value="read" checked', fixed = TRUE)
  expect_false(grepl('value="write" checked', page$body, fixed = TRUE))

  # A browser sends this page's form with its origin, not with "null".
  expect_identical(page$headers[["Referrer-Policy"]], "same-origin")

  # The document is remembered for a while.
  page2 <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client), cookies), s$app))
  expect_identical(page2$status, 200L)
  expect_identical(sum(mock$requests[-seq_len(before)] == client$client_id), 1L)

  resp <- handle_request(form_post("/oauth/approve", c(approval_fields(page), list(decision = "cancel")), cookies), s$app)
  expect_identical(resp$status, 303L)
  returned <- url_query(resp$headers[["Location"]])
  expect_identical(returned$error, "access_denied")
  expect_identical(returned$state, "app-state-1")
  expect_identical(returned$iss, "http://localhost:8080")
  expect_null(returned$code)
  expect_identical(count(s$DB, "app_grants"), 0L)

  # A guest is not an account: sent to sign in.
  guest   <- add_test_user(s$DB, "Guest 9", is_guest = TRUE)
  session <- add_test_session(s$DB, guest, add_test_project(s$DB, guest)$project_id)
  resp    <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client), list(auth_token = session$auth_token)), s$app))
  expect_identical(resp$status, 302L)
  expect_match(resp$headers[["Location"]], "^/auth/login")
})


# Refusals ------------------------------------------------------------------------

test_that("an app that cannot be identified gets a page, never a redirect", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)
  cookies <- sign_in_through(s$app, mock)$cookies

  refused <- function (query, status = 400L, message = NULL) {
    resp <- settled(handle_request(browser_get("/oauth/authorize", query, cookies), s$app))
    expect_identical(resp$status, status, info = query)
    expect_match(resp$headers[["Content-Type"]], "text/html", info = query)
    expect_null(resp$headers[["Location"]])
    if (!is.null(message)) expect_match(resp$body, message, fixed = TRUE, info = query)
    resp
  }

  refused("", message = "missing its client_id or redirect_uri")

  # The client_id: https, with a path, on the public internet.
  for (bad in c(
      "http://app.test/client.json", "https://app.test", "https://app.test/", "app-123",
      "https://user@app.test/client.json", "https://app.test/a/../client.json" ))
    refused(authorize_query(client, client_id = bad), message = "its client_id")

  # A host that resolves to this computer, a private network, a link-local
  # address (where cloud machines keep their credentials), or nowhere.
  for (address in list("127.0.0.1", "10.1.2.3", "192.168.1.5", "169.254.169.254", "::1", "fd00::1", c("93.184.216.34", "10.0.0.1"), character(0))) {
    local_mocked_bindings(host_addresses = function (host) address)
    resp <- refused(authorize_query(client, client_id = "https://internal.test/client.json"), message = "its client_id")
  }
  expect_false("https://internal.test/client.json" %in% mock$requests)

  local_mocked_bindings(host_addresses = function (host) "93.184.216.34")

  # The document: there, JSON, about this client, with a name and
  # redirect addresses, and for a public client.
  doc <- mock$documents[[client$client_id]]
  bad <- list(
    missing    = 404L,
    redirect   = 302L,
    not_json   = "<html>hello</html>",
    array      = "[1, 2]",
    other_id   = utils::modifyList(doc, list(client_id = "https://app.test/oauth/other.json")),
    no_name    = doc[setdiff(names(doc), "client_name")],
    no_uris    = doc[setdiff(names(doc), "redirect_uris")],
    secret     = utils::modifyList(doc, list(token_endpoint_auth_method = "client_secret_basic")),
    too_large  = paste0('{"client_id":"x","pad":"', strrep("a", 70000), '"}') )

  for (name in names(bad)) {
    id <- sprintf("https://app.test/oauth/%s.json", name)
    mock$documents[[id]] <- if (is.list(bad[[name]]) && is.null(bad[[name]]$client_id)) c(list(client_id = id), bad[[name]]) else bad[[name]]
    if (name %in% c("no_name", "no_uris", "secret")) mock$documents[[id]]$client_id <- id
    refused(authorize_query(client, client_id = id), status = if (name %in% c("missing", "redirect", "too_large")) 502L else 400L, message = "This app cannot connect")
  }

  # The redirect address: one the app registered, and https or local.
  refused(authorize_query(client, redirect_uri = "https://evil.test/callback"), message = "not one it has registered")
  refused(authorize_query(client, redirect_uri = "https://app.test/callback/other"), message = "not one it has registered")
  refused(authorize_query(client, redirect_uri = "http://app.test/callback"), message = "must be https")
  refused(authorize_query(client, redirect_uri = "javascript:alert(1)"), message = "must be https")

  expect_identical(count(s$DB, "app_grants"), 0L)
  expect_length(s$REQ$AUTH$oauth$codes, 0)
})


test_that("an app on this computer may come back on any port, and the page says so", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock, name = "Desk App", redirect_uri = "http://localhost/callback")
  mock$documents[[client$client_id]]$redirect_uris <- list("http://localhost/callback", "http://127.0.0.1/callback")
  cookies <- sign_in_through(s$app, mock)$cookies

  client$redirect_uri <- "http://localhost:51234/callback"
  out <- connect_app(s$app, mock, client, cookies)

  expect_match(out$page$body, "returned to: <strong>an app on this computer</strong>", fixed = TRUE)
  expect_match(out$page$body, "Any program on this computer could be asking under this name", fixed = TRUE)
  expect_match(out$page$headers[["Content-Security-Policy"]], "form-action 'self' http://localhost:51234", fixed = TRUE)
  expect_match(out$approve$headers[["Location"]], "^http://localhost:51234/callback\\?code=")
  expect_identical(out$token$status, 200L)

  # The port is all that may differ.
  expect_true(oauth_redirect_matches("http://127.0.0.1:8/callback", c("http://localhost/callback", "http://127.0.0.1/callback")))
  expect_false(oauth_redirect_matches("http://localhost:51234/other", "http://localhost/callback"))
  expect_false(oauth_redirect_matches("https://localhost:51234/callback", "http://localhost/callback"))
  expect_false(oauth_redirect_matches("http://localhost.evil.test:51234/callback", "http://localhost/callback"))
  expect_false(oauth_redirect_matches("https://app.test:8443/callback", "https://app.test/callback"))
  expect_true(oauth_redirect_matches("https://app.test/callback", "https://app.test/callback"))
})


test_that("a request that is wrong in itself is returned to the app with the reason", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)
  cookies <- sign_in_through(s$app, mock)$cookies

  returned <- function (...) {
    resp <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client, ...), cookies), s$app))
    expect_identical(resp$status, 303L)
    expect_match(resp$headers[["Location"]], "^https://app\\.test/callback\\?")
    out <- url_query(resp$headers[["Location"]])
    expect_identical(out$iss, "http://localhost:8080")
    expect_identical(out$state, "app-state-1")
    expect_null(out$code)
    out$error
  }

  expect_identical(returned(response_type = "token"), "unsupported_response_type")
  expect_identical(returned(code_challenge_method = "plain"), "invalid_request")
  expect_identical(returned(code_challenge = "short"), "invalid_request")
  expect_identical(returned(resource = "https://elsewhere.test/mcp"), "invalid_target")
  expect_identical(returned(scope = "read admin"), "invalid_scope")

  # A trailing slash on the resource, and the scope some apps add to ask
  # for a refresh token, are fine.
  page <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client, resource = "http://localhost:8080/mcp/", scope = "read offline_access"), cookies), s$app))
  expect_identical(page$status, 200L)
})


test_that("the approval counts once, from the page it was shown on, to the person it was shown to", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)
  cookies <- sign_in_through(s$app, mock)$cookies

  page   <- function () settled(handle_request(browser_get("/oauth/authorize", authorize_query(client), cookies), s$app))
  answer <- function (fields, cookies) handle_request(form_post("/oauth/approve", fields, cookies), s$app)

  # The wrong value for this page view.
  fields <- c(approval_fields(page()), list(decision = "connect"))
  resp   <- answer(utils::modifyList(fields, list(csrf = random_string(43))), cookies)
  expect_identical(resp$status, 403L)
  expect_match(resp$headers[["Content-Type"]], "text/html")
  # And that used the request up.
  expect_identical(answer(fields, cookies)$status, 400L)

  # Nobody signed in; somebody else signed in.
  fields <- c(approval_fields(page()), list(decision = "connect"))
  expect_identical(answer(fields, list())$status, 403L)

  other   <- add_test_user(s$DB, "Somebody Else")
  session <- add_test_session(s$DB, other, add_test_project(s$DB, other)$project_id)
  fields  <- c(approval_fields(page()), list(decision = "connect"))
  expect_identical(answer(fields, list(auth_token = session$auth_token))$status, 403L)

  # A form on another site, or one whose page hid where it came from.
  for (origin in c("https://evil.test", "null")) {
    fields  <- c(approval_fields(page()), list(decision = "connect"))
    request <- form_post("/oauth/approve", fields, cookies)
    request$HEADERS <- c(origin = origin)
    expect_identical(handle_request(request, s$app)$status, 403L)
  }

  # The browser's own form, as it sends it.
  fields  <- c(approval_fields(page()), list(decision = "connect"))
  request <- form_post("/oauth/approve", fields, cookies)
  request$HEADERS <- c(origin = "http://localhost:8080", "sec-fetch-site" = "same-origin")
  expect_identical(handle_request(request, s$app)$status, 303L)

  # Once.
  fields <- c(approval_fields(page()), list(decision = "connect"))
  expect_identical(answer(fields, cookies)$status, 303L)
  expect_identical(answer(fields, cookies)$status, 400L)

  # A request that was never made, or has run out.
  expect_identical(answer(list(request = random_string(43), csrf = random_string(43), decision = "connect"), cookies)$status, 400L)

  fields <- approval_fields(page())
  s$REQ$AUTH$oauth$requests[[fields$request]]$created <- Sys.time() - 3600
  expect_identical(answer(c(fields, list(decision = "connect")), cookies)$status, 400L)

  expect_identical(count(s$DB, "app_grants"), 0L)
})


test_that("the token endpoint gives tokens only for a code used properly", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)
  cookies <- sign_in_through(s$app, mock)$cookies

  code <- function () {
    page <- settled(handle_request(browser_get("/oauth/authorize", authorize_query(client), cookies), s$app))
    resp <- handle_request(form_post("/oauth/approve", c(approval_fields(page), list(decision = "connect")), cookies), s$app)
    url_query(resp$headers[["Location"]])$code
  }

  exchange <- function (...) {
    fields <- utils::modifyList(list(
      grant_type = "authorization_code", client_id = client$client_id, redirect_uri = client$redirect_uri,
      code_verifier = client$verifier ), list(...))
    resp <- handle_request(form_post("/oauth/token", fields), s$app)
    c(list(status = resp$status), response_json(resp))
  }

  refused <- function (out, error = "invalid_grant") {
    expect_identical(out$status, 400L)
    expect_identical(out$error, error)
    expect_true(nzchar(out$error_description))
    expect_null(out$access_token)
  }

  refused(exchange(code = code(), code_verifier = random_string(64)))
  refused(exchange(code = code(), code_verifier = "short"))
  refused(exchange(code = code(), client_id = "https://other.test/client.json"))
  refused(exchange(code = code(), redirect_uri = "https://app.test/elsewhere"))
  refused(exchange(code = code(), resource = "https://elsewhere.test/mcp"), "invalid_target")
  refused(exchange(code = paste0("x", random_string(47))))
  refused(exchange(code = code(), grant_type = "password"), "unsupported_grant_type")
  refused(exchange(code = code(), grant_type = "client_credentials"), "unsupported_grant_type")
  refused(exchange(), "invalid_request")
  refused(exchange(code = code(), client_id = NULL), "invalid_request")

  # Every attempt that got as far as its code used the code up. (The four
  # refused before that left theirs to run out.)
  expect_length(s$REQ$AUTH$oauth$codes, 4)

  # A code that is a minute old.
  old <- code()
  key <- as.character(openssl::sha256(old))
  s$REQ$AUTH$oauth$codes[[key]]$created <- Sys.time() - 61
  refused(exchange(code = old))

  # A code works once.
  good <- code()
  expect_identical(exchange(code = good)$status, 200L)
  refused(exchange(code = good))

  expect_identical(count(s$DB, "app_grants"), 1L)

  # The account was removed between approval and exchange.
  last <- code()
  db_query(s$DB, "DELETE FROM users WHERE sub = 'sub-ada'", "T1")
  refused(exchange(code = last))
})


test_that("a refresh token used twice ends the connection", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)

  refresh <- function (token) {
    resp <- handle_request(form_post("/oauth/token", list(grant_type = "refresh_token", refresh_token = token, client_id = client$client_id)), s$app)
    c(list(status = resp$status), response_json(resp))
  }

  first  <- connect_app(s$app, mock, client)$tokens
  second <- refresh(first$refresh_token)
  expect_identical(second$status, 200L)

  # Presented again at once: an app that refreshed from two places. It is
  # refused, and the connection stays.
  again <- refresh(first$refresh_token)
  expect_identical(again$status, 400L)
  expect_identical(again$error, "invalid_grant")
  expect_identical(count(s$DB, "app_grants"), 1L)
  expect_identical(handle_request(mcp_as(second$access_token, "tools/list"), s$app)$status, 200L)

  # Presented again later: someone has a copy. Everything of the
  # connection goes, the newest tokens too.
  db_query(s$DB, "UPDATE app_tokens SET replaced_utc = ? WHERE replaced_utc IS NOT NULL", "T1", list(sql_time(Sys.time() - 300)))
  log   <- local_log()
  again <- refresh(first$refresh_token)
  expect_identical(again$error, "invalid_grant")
  expect_identical(count(s$DB, "app_grants"), 0L)
  expect_identical(count(s$DB, "app_tokens"), 0L)
  expect_identical(handle_request(mcp_as(second$access_token, "tools/list"), s$app)$status, 401L)
  expect_identical(refresh(second$refresh_token)$error, "invalid_grant")
  expect_true("app_refresh_reused" %in% vapply(log(), function (e) e$event, character(1)))

  # An access token is not a refresh token.
  third <- connect_app(s$app, mock, client)$tokens
  expect_identical(refresh(third$access_token)$error, "invalid_grant")
  expect_identical(refresh("")$status, 400L)
})


test_that("tokens and connections run out", {

  s     <- local_oauth_app()
  user  <- add_test_user(s$DB, "Ada Lovelace")
  grant <- add_test_grant(s$DB, user, "read")
  token <- grant$access_token

  ok <- function () handle_request(mcp_as(token, "tools/list"), s$app)$status

  expect_identical(ok(), 200L)

  # The access token, after its hour.
  db_query(s$DB, "UPDATE app_tokens SET expires_utc = ?", "T1", list(sql_time(Sys.time() - 1)))
  expect_identical(ok(), 401L)
  db_query(s$DB, "UPDATE app_tokens SET expires_utc = ?", "T2", list(sql_time(Sys.time() + 3600)))
  expect_identical(ok(), 200L)

  # The connection, after its days without use.
  db_query(s$DB, "UPDATE app_grants SET expires_utc = ?", "T3", list(sql_time(Sys.time() - 1)))
  expect_identical(ok(), 401L)
  db_query(s$DB, "UPDATE app_grants SET expires_utc = ?", "T4", list(sql_time(Sys.time() + 3600)))

  # A token issued for some other resource.
  db_query(s$DB, "UPDATE app_grants SET resource = 'https://elsewhere.test/mcp'", "T5")
  expect_identical(ok(), 401L)
  db_query(s$DB, "UPDATE app_grants SET resource = 'http://localhost:8080/mcp'", "T6")

  # Cleanup removes what has run out, and only that.
  other <- add_test_grant(s$DB, user, "read")
  db_query(s$DB, "UPDATE app_grants SET expires_utc = ? WHERE grant_id = ?", "T7", list(sql_time(Sys.time() - 1), other$grant_id))
  removed <- cleanup_run(s$DB, s$REQ$CONFIG)
  expect_identical(removed$apps, 1L)
  expect_identical(count(s$DB, "app_tokens"), 1L)
  expect_identical(db_query(s$DB, "SELECT grant_id FROM app_grants", "T8"), grant$grant_id)
  expect_identical(ok(), 200L)

  # The account goes: its connections go with it.
  db_query(s$DB, "DELETE FROM users WHERE user_id = ?", "T9", list(user))
  expect_identical(ok(), 401L)
  expect_identical(count(s$DB, "app_tokens"), 0L)
})


test_that("signing out of the browser leaves apps connected; revoking ends one", {

  s      <- local_oauth_app()
  mock   <- local_mock_issuer()
  client <- local_mock_app(mock)

  out    <- connect_app(s$app, mock, client)
  tokens <- out$tokens

  session <- handle_request(browser_post_init(out$cookies), s$app)
  request <- fake_request("POST", "/api/account/sign_out", list(), session_from(session))
  expect_identical(handle_request(request, s$app)$status, 200L)
  expect_identical(handle_request(mcp_as(tokens$access_token, "tools/list"), s$app)$status, 200L)

  # The app gives the connection up itself. The answer is the same for a
  # token nobody knows.
  for (token in c(paste0("atr_", random_string(48)), tokens$refresh_token)) {
    resp <- handle_request(form_post("/oauth/revoke", list(token = token, token_type_hint = "refresh_token")), s$app)
    expect_identical(resp$status, 200L)
  }

  expect_identical(count(s$DB, "app_grants"), 0L)
  expect_identical(handle_request(mcp_as(tokens$access_token, "tools/list"), s$app)$status, 401L)
})


test_that("a person can only disconnect their own apps", {

  s     <- local_oauth_app()
  ada   <- add_test_user(s$DB, "Ada Lovelace")
  bob   <- add_test_user(s$DB, "Bob Example")
  mine  <- add_test_grant(s$DB, ada)
  also  <- add_test_grant(s$DB, ada, name = "Second App")
  theirs <- add_test_grant(s$DB, bob)

  session <- add_test_session(s$DB, ada, add_test_project(s$DB, ada)$project_id)
  api     <- function (path, args = list()) handle_request(fake_request("POST", path, args, session), s$app)

  expect_identical(api("/api/apps/disconnect", list(grant_id = theirs$grant_id))$status, 404L)
  expect_identical(count(s$DB, "app_grants"), 3L)

  # All of one's own at once.
  expect_identical(response_json(api("/api/apps/disconnect"))$disconnected, 2L)
  expect_identical(db_query(s$DB, "SELECT grant_id FROM app_grants", "T1"), theirs$grant_id)

  # A guest has no apps and no page for them.
  guest   <- add_test_user(s$DB, "Guest 3", is_guest = TRUE)
  session <- add_test_session(s$DB, guest, add_test_project(s$DB, guest)$project_id)
  expect_identical(api("/api/apps/list")$status, 403L)
})


# Parts -------------------------------------------------------------------------

test_that("only addresses on the public internet count as public", {

  public  <- c("93.184.216.34", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111", "[2606:4700::1]")
  private <- c(
    "127.0.0.1", "127.8.8.8", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.0.1", "169.254.169.254",
    "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.0.1", "198.18.0.1",
    "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:10.0.0.1", "::ffff:8.8.8.8", "64:ff9b::a00:1",
    "999.1.1.1", "localhost", "", NA_character_ )

  for (address in public)  expect_true(is_public_address(address), info = address)
  for (address in private) expect_false(is_public_address(address), info = address)

  # The fetch is pinned to an address that was checked.
  local_mocked_bindings(host_addresses = function (host) c("93.184.216.34", "93.184.216.35"))
  target <- oauth_client_target("https://app.test:8443/oauth/client.json")
  expect_identical(target$resolve, "app.test:8443:93.184.216.34")
  expect_identical(oauth_client_target("https://app.test/c.json")$resolve, "app.test:443:93.184.216.34")
})


test_that("the sign-in may return to an approval page, and nowhere else new", {

  request <- paste0("/oauth/authorize?request=", strrep("a", 43))

  expect_identical(oidc_return_to(request), request)
  expect_identical(oidc_return_to("/hmp50"), "/hmp50")

  for (bad in c(
      "/oauth/authorize", "/oauth/authorize?request=short", paste0(request, "&x=1"),
      "/oauth/authorize?client_id=https://evil.test/c.json", "/oauth/token", "//evil.test", "https://evil.test/" ))
    expect_identical(oidc_return_to(bad), "/", info = bad)
})
