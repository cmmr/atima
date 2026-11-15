# Usage monitoring: what is recorded, the roll-ups, how long rows are kept,
# and who may read the numbers (R/usage.R, R/usage-report.R).


# A shared server with one public project, and the people of the tests.
local_usage_setup <- function (env = parent.frame(), auth = "oidc") {

  REQ <- local_test_req(env, auth = auth)
  DB  <- REQ$DB
  local_fake_biom(env)

  users <- list(
    guest = add_test_user(DB, "Guest 1", is_guest = TRUE),
    ada   = add_test_user(DB, "Ada Lovelace"),
    admin = add_test_user(DB, "Adam Admin", is_admin = TRUE) )

  project_id <- add_test_project(DB, users$ada, is_public = TRUE)$project_id

  app <- test_app(REQ)

  list(
    REQ = REQ, DB = DB, app = app, users = users, project_id = project_id,
    sessions = lapply(users, function (user_id) add_test_session(DB, user_id, project_id)),
    post = function (path, args = list(), session = NULL, agent = NULL, address = NULL) {
      request <- fake_request("POST", path, args, session)
      request$HTTP_HOST <- "localhost:8080"
      if (!is.null(agent))   request$HTTP_USER_AGENT <- agent
      if (!is.null(address)) request$REMOTE_ADDR <- address
      handle_request(request, app)
    },
    get = function (path, agent = "Mozilla/5.0 Test", address = "203.0.113.7") {
      request <- fake_request("GET", path)
      request$HTTP_HOST       <- "localhost:8080"
      request$HTTP_USER_AGENT <- agent
      request$REMOTE_ADDR     <- address
      handle_request(request, app)
    })
}

usage_tables <- c(
  "usage_events", "usage_arrivals", "usage_visitors", "usage_people", "usage_person_days",
  "usage_daily_actions", "usage_daily_arrivals", "usage_daily", "usage_requests", "usage_hours" )


#______________________________________________________________________________
# A local install

test_that("a local install records nothing and has no usage route", {

  setup <- local_usage_setup(auth = "none")
  DB    <- setup$DB

  expect_false(usage_on(setup$REQ$CONFIG))

  init <- handle_request(fake_request("POST", "/api/session/init", list(referrer = "https://example.org/page")), setup$app)
  expect_identical(init$status, 200L)
  expect_false(response_json(init)$CONF$usage)

  session <- session_from(init)
  expect_identical(handle_request(fake_request("POST", "/api/tree/create", list(node_id = "#"), session), setup$app)$status, 200L)
  expect_identical(handle_request(fake_request("GET", "/"), setup$app)$status, 200L)
  expect_identical(handle_request(fake_request("GET", "/api/health"), setup$app)$status, 200L)
  handle_request(fake_request("POST", "/api/plot", list(plot_fn = "nonsense"), session), setup$app)

  for (table in usage_tables)
    expect_identical(nrow(usage_rows(DB, table)), 0L, info = table)

  # The route is not there, whoever asks; and the report refuses too.
  expect_identical(handle_request(fake_request("POST", "/api/usage/data", list(), session), setup$app)$status, 404L)
  expect_error(api_usage_data(setup$REQ), class = "atima_http_error")

  # Switched off on a shared server: the same.
  expect_true(usage_on(list(auth = "oidc")))
  expect_false(usage_on(list(auth = "oidc", usage = FALSE)))
  expect_false(usage_on(list(auth = "none", usage = TRUE)))
})


test_that("a shared server with usage switched off records nothing", {

  setup <- local_usage_setup()
  setup$REQ$CONFIG$usage <- FALSE
  app <- test_app(setup$REQ)

  expect_identical(handle_request(fake_request("POST", "/api/tree/create", list(node_id = "#"), setup$sessions$ada), app)$status, 200L)

  for (table in usage_tables)
    expect_identical(nrow(usage_rows(setup$DB, table)), 0L, info = table)

  resp <- handle_request(fake_request("POST", "/api/usage/data", list(), setup$sessions$admin), app)
  expect_identical(resp$status, 404L)
})


#______________________________________________________________________________
# What is recorded

test_that("every route that is an action says what kind, and the rest say nothing", {

  routes <- route_table()
  kinds  <- vapply(routes, function (r) r$usage %||% NA_character_, character(1))
  names(kinds) <- vapply(routes, function (r) r$endpoint, character(1))

  expect_true(all(kinds[!is.na(kinds)] %in% usage_kinds))
  expect_true(all(usage_analyses %in% usage_kinds))

  expect_identical(kinds[["POST /api/session/init"]], "visit")
  expect_identical(kinds[["POST /api/plot"]], "plot")
  expect_identical(kinds[["POST /api/metadata/add_clusters"]], "clusters")
  expect_identical(kinds[["POST /api/project/upload"]], "upload")
  expect_identical(kinds[["POST /api/project/export"]], "export")
  expect_identical(kinds[["POST /api/project/save"]], "save")
  expect_identical(kinds[["POST /api/project/publish"]], "publish")
  expect_identical(kinds[["POST /api/sharing/update"]], "share")
  expect_identical(kinds[["POST /api/legacy/start"]], "import")
  expect_identical(kinds[["GET /:access_key/:file"]], "download")
  expect_identical(kinds[["GET /"]], "page")

  # Not something a person does.
  for (endpoint in c("POST /api/session/heartbeat", "GET /api/health", "POST /api/schema", "POST /api/usage/data",
                     "POST /oauth/token", "GET /.well-known/oauth-authorization-server", "POST /mcp"))
    expect_true(is.na(kinds[[endpoint]]), info = endpoint)

  # Every tool an AI app can call has a kind.
  expect_setequal(names(usage_tool_kinds), names(mcp_tool_table()))
  expect_true(all(usage_tool_kinds %in% usage_kinds))
})


test_that("an action is recorded once, with its kind, function, interface and outcome", {

  setup <- local_usage_setup()
  DB    <- setup$DB
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  ada <- setup$sessions$ada

  expect_identical(setup$post("/api/plot", list(plot_fn = "bdiv_ord_plot", plot_args = list(), depth = 1000), ada)$status, 200L)
  expect_identical(setup$post("/api/metadata/add_clusters", list(cluster_fn = "taxa_clusters", name = "Groups"), ada)$status, 200L)
  expect_identical(setup$post("/api/project/export", list(what = "metadata"), ada)$status, 200L)
  expect_identical(setup$post("/api/project/save", list(title = "My study", description = "<p>x</p>"), ada)$status, 200L)
  expect_identical(setup$post("/api/session/heartbeat", list(), ada)$status, 200L)

  events <- usage_rows(DB)

  expect_identical(events$kind, c("plot", "clusters", "export", "save"))
  expect_identical(events$fn,   c("bdiv_ord_plot", "taxa_clusters", NA, NA))
  expect_identical(events$area, c("beta", "taxa", NA, NA))
  expect_true(all(events$interface == "ui"))
  expect_true(all(events$outcome == "done"))
  expect_true(all(events$class == "user"))
  expect_true(all(events$user_id == setup$users$ada))
  expect_true(all(events$is_account == 1))
  expect_true(all(is.na(events$app)))
  expect_true(all(events$total_ms >= 0))

  # Every request is counted, the heartbeat too; only actions are rows.
  expect_identical(usage_rows(DB, "usage_requests")$requests, 5L)

  # A guest is a person without an account.
  expect_identical(setup$post("/api/project/export", list(what = "metadata"), setup$sessions$guest)$status, 200L)
  last <- utils::tail(usage_rows(DB), 1)
  expect_identical(last$user_id, setup$users$guest)
  expect_identical(last$is_account, 0L)
})


test_that("how a request ended is recorded: rejected, denied, failed", {

  setup <- local_usage_setup()
  DB    <- setup$DB
  ada   <- setup$sessions$ada

  # A wrong argument, before any handler.
  expect_identical(setup$post("/api/plot", list(plot_fn = "no_such_plot", plot_args = list(), depth = 10), ada)$status, 400L)
  # No session.
  expect_identical(setup$post("/api/project/export", list(what = "metadata"))$status, 401L)
  # The handler fails.
  local_mocked_bindings(call_handler = function (...) stop("boom"))
  expect_identical(setup$post("/api/project/export", list(what = "metadata"), ada)$status, 500L)

  events <- usage_rows(DB)

  expect_identical(events$kind,    c("plot", "export", "export"))
  expect_identical(events$outcome, c("rejected", "denied", "failed"))
  expect_identical(events$class,   c("user", "anonymous", "user"))
  expect_true(is.na(events$fn[[1]]))
})


test_that("outcomes follow the error or the status", {

  http <- function (status, message = "x") http_condition(status, message)

  expect_identical(usage_outcome(NULL, 200L), "done")
  expect_identical(usage_outcome(NULL, 303L), "done")
  expect_identical(usage_outcome(NULL, 400L), "rejected")
  expect_identical(usage_outcome(NULL, 404L), "rejected")
  expect_identical(usage_outcome(NULL, 409L), "cancelled")
  expect_identical(usage_outcome(http(401L), 200L), "denied")
  expect_identical(usage_outcome(http(403L), 200L), "denied")
  expect_identical(usage_outcome(http(409L, "This request was replaced by a newer one."), 409L), "replaced")
  expect_identical(usage_outcome(http(409L, "This request was cancelled."), 409L), "cancelled")
  expect_identical(usage_outcome(http(429L), 429L), "limited")
  expect_identical(usage_outcome(http(503L), 503L), "busy")
  expect_identical(usage_outcome(http(504L), 504L), "timeout")
  expect_identical(usage_outcome(simpleError("boom"), 200L), "failed")
  expect_identical(usage_outcome(NULL, NULL), "failed")

  # The same wording the pool uses, so "replaced" is told from "cancelled".
  expect_match(deparse(body(pool_submit)), "replaced by a newer one", all = FALSE)
})


test_that("a visit is recorded with where it came from, and nothing else of the request", {

  setup <- local_usage_setup()
  DB    <- setup$DB

  places <- withr::local_tempfile(fileext = ".mmdb")
  write_test_mmdb(places, list("203.0.113.0/24" = list(
    country = list(iso_code = "DE"), autonomous_system_organization = "Example University")))
  setup$app$geo <- geo_open(places)

  post <- function (args, address = "203.0.113.7") {
    request <- fake_request("POST", "/api/session/init", args)
    request$HTTP_HOST   <- "localhost:8080"
    request$REMOTE_ADDR <- address
    handle_request(request, setup$app)
  }

  expect_identical(post(list(referrer = "https://www.Example.org/tools/microbiome?utm_source=news&token=SECRETTOKEN#frag"))$status, 200L)
  expect_identical(post(list(referrer = "http://localhost:8080/hmp50"), address = "198.51.100.1")$status, 200L)
  expect_identical(post(list(referrer = "android-app://com.example"))$status, 200L)
  expect_identical(post(list())$status, 200L)

  events   <- usage_rows(DB)
  arrivals <- usage_rows(DB, "usage_arrivals")

  expect_identical(events$kind, rep("visit", 4))
  expect_identical(nrow(arrivals), 4L)

  expect_identical(arrivals$ref_host, c("example.org", NA, NA, NA))
  expect_identical(arrivals$ref_path, c("/tools/microbiome", NA, NA, NA))
  expect_identical(arrivals$country,  c("DE", NA, "DE", "DE"))
  expect_identical(arrivals$network,  c("Example University", NA, "Example University", "Example University"))
  expect_identical(arrivals$user_id, events$user_id)

  # The address, the query string and the cookie are nowhere in the record.
  dump <- usage_dump(DB)
  expect_no_match(dump, "203.0.113", fixed = TRUE)
  expect_no_match(dump, "198.51.100", fixed = TRUE)
  expect_no_match(dump, "SECRETTOKEN", fixed = TRUE)
  expect_no_match(dump, "utm_source", fixed = TRUE)

  # A failed start is no visit.
  DBI::dbExecute(DB, "UPDATE projects SET deleted_utc = CURRENT_TIMESTAMP")
  expect_identical(post(list(referrer = "https://example.net/"))$status, 404L)
  expect_identical(nrow(usage_rows(DB, "usage_arrivals")), 4L)
  expect_identical(utils::tail(usage_rows(DB), 1)$outcome, "rejected")
})


test_that("referrers are reduced to a host and a path", {

  config <- list(public_url = "https://atima.example.edu")

  expect_identical(usage_referrer("https://github.com/cmmr/rbiom/", config), list(host = "github.com", path = "/cmmr/rbiom"))
  expect_identical(usage_referrer("https://www.google.com/", config), list(host = "google.com", path = NULL))
  expect_identical(usage_referrer("https://google.com", config), list(host = "google.com", path = NULL))
  expect_identical(usage_referrer("HTTPS://User:Pass@Example.ORG:8443/a/b?c=d#e", config), list(host = "example.org", path = "/a/b"))
  expect_identical(usage_referrer(paste0("https://example.org/", strrep("a", 500)), config)$path, paste0("/", strrep("a", 199)))

  expect_null(usage_referrer("https://atima.example.edu/hmp50", config))
  expect_null(usage_referrer("https://www.atima.example.edu/", config))
  expect_null(usage_referrer("ftp://example.org/file", config))
  expect_null(usage_referrer("javascript:alert(1)", config))
  expect_null(usage_referrer("https://localhost/x", config))
  expect_null(usage_referrer("https://exa mple.org/", config))
  expect_null(usage_referrer("", config))
  expect_null(usage_referrer(NULL, config))
  expect_null(usage_referrer(NA_character_, config))
})


test_that("nothing from a request's arguments or from a project reaches the record", {

  setup <- local_usage_setup()
  DB    <- setup$DB
  ada   <- setup$sessions$ada
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  DBI::dbExecute(DB, "UPDATE projects SET title = 'PRIVATETITLE', description = 'PRIVATEDESCRIPTION'")
  DBI::dbExecute(DB, "UPDATE users SET email = 'ada@private.example', full_name = 'PRIVATENAME' WHERE user_id = ?", params = list(setup$users$ada))

  setup$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "PRIVATEFIELD"), depth = 12345,
    subset_args = list(cat = list(PRIVATEFIELD = list("PRIVATEVALUE")))), ada, address = "203.0.113.99")
  setup$post("/api/project/save", list(title = "PRIVATETITLE two", description = "<p>PRIVATEDESCRIPTION</p>"), ada)
  setup$post("/api/metadata/add_clusters", list(cluster_fn = "taxa_clusters", name = "PRIVATECLUSTERS"), ada)
  setup$post("/api/sharing/user_search", list(query = "PRIVATEQUERY"), ada)

  usage_rollup(DB)

  expect_gte(nrow(usage_rows(DB)), 2L)

  dump <- usage_dump(DB)
  expect_no_match(dump, "PRIVATE", fixed = TRUE)
  expect_no_match(dump, "private.example", fixed = TRUE)
  expect_no_match(dump, "12345", fixed = TRUE)
  expect_no_match(dump, "203.0.113", fixed = TRUE)
  expect_no_match(dump, ada$session_key, fixed = TRUE)
  expect_no_match(dump, ada$auth_token, fixed = TRUE)
})


test_that("administrators, crawlers, load tests and health checks are told apart from people", {

  setup <- local_usage_setup()
  DB    <- setup$DB
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  export <- function (session, agent = NULL) setup$post("/api/project/export", list(what = "metadata"), session, agent = agent)

  export(setup$sessions$ada, "Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0")
  export(setup$sessions$admin)
  export(setup$sessions$ada, "atima-loadtest")
  export(setup$sessions$ada, "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)")
  export(NULL, "curl/8.5.0")

  expect_identical(usage_rows(DB)$class, c("user", "admin", "loadtest", "bot", "anonymous"))

  # A health check is counted as a request and is no action.
  request <- fake_request("GET", "/api/health")
  request$HTTP_HOST <- "localhost:8080"
  expect_identical(handle_request(request, setup$app)$status, 200L)
  expect_identical(nrow(usage_rows(DB)), 5L)

  requests <- usage_rows(DB, "usage_requests")
  expect_identical(requests$requests[requests$class == "health"], 1L)
  expect_setequal(requests$class, c("user", "admin", "loadtest", "bot", "anonymous", "health"))

  agents <- c(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0 Safari/537.36" = "user",
    "Mozilla/5.0 (compatible; bingbot/2.0)" = "bot",
    "Slackbot-LinkExpanding 1.0" = "bot",
    "facebookexternalhit/1.1" = "bot",
    "UptimeRobot/2.0" = "bot",
    "Mozilla/5.0 HeadlessChrome/120.0" = "bot",
    "R (4.5.1 x86_64-pc-linux-gnu)" = "user",
    "atima-loadtest/1" = "loadtest" )

  for (agent in names(agents))
    expect_identical(usage_who(DB, setup$users$ada, agent, "/api/plot")$class, agents[[agent]], info = agent)

  expect_identical(usage_who(DB, NULL, "", "/")$class, "anonymous")
  expect_identical(usage_who(DB, 999999L, NULL, "/")$class, "anonymous")
})


test_that("requests without a cookie are counted by a daily hash, and the secret is not stored", {

  setup <- local_usage_setup()
  DB    <- setup$DB

  expect_identical(setup$get("/")$status, 200L)
  expect_identical(setup$get("/hmp50")$status, 200L)
  expect_identical(setup$get("/", address = "203.0.113.8")$status, 200L)
  expect_identical(setup$get("/", agent = "Mozilla/5.0 (compatible; Googlebot/2.1)")$status, 200L)

  visitors <- usage_rows(DB, "usage_visitors")

  expect_identical(nrow(visitors), 3L)
  expect_setequal(visitors$hits, c(2L, 1L, 1L))
  expect_setequal(visitors$class, c("anonymous", "anonymous", "bot"))
  expect_true(all(visitors$has_session == 0L))
  expect_true(all(grepl("^[0-9a-f]{24}$", visitors$visitor)))

  # Loading the page is no action.
  expect_identical(nrow(usage_rows(DB)), 0L)

  # The same browser then starts a session: it is a person from here on.
  request <- fake_request("POST", "/api/session/init", list())
  request$HTTP_HOST       <- "localhost:8080"
  request$HTTP_USER_AGENT <- "Mozilla/5.0 Test"
  request$REMOTE_ADDR     <- "203.0.113.7"
  expect_identical(handle_request(request, setup$app)$status, 200L)

  visitors <- usage_rows(DB, "usage_visitors")
  expect_identical(visitors$has_session[visitors$hits == 2L], 1L)
  expect_identical(sum(visitors$has_session), 1L)

  # Someone with a cookie is not a visitor without one.
  request <- fake_request("GET", "/", session = setup$sessions$ada)
  request$HTTP_HOST <- "localhost:8080"
  handle_request(request, setup$app)
  expect_identical(nrow(usage_rows(DB, "usage_visitors")), 3L)

  # The hash is the same all day, differs by address and agent, and
  # cannot be made again the next day.
  day  <- usage_day(Sys.time())
  hash <- usage_visitor_hash(day, "203.0.113.7", "Mozilla/5.0 Test")
  expect_true(hash %in% visitors$visitor)
  expect_identical(usage_visitor_hash(day, "203.0.113.7", "Mozilla/5.0 Test"), hash)
  expect_false(identical(usage_visitor_hash(day, "203.0.113.8", "Mozilla/5.0 Test"), hash))
  expect_false(identical(usage_visitor_hash(day, "203.0.113.7", "Other"), hash))

  secret <- usage_env$secret
  expect_match(secret, "^[A-Za-z0-9]{48}$")

  expect_false(identical(usage_visitor_hash("2099-01-01", "203.0.113.7", "Mozilla/5.0 Test"), hash))
  expect_false(identical(usage_env$secret, secret))
  expect_false(identical(usage_visitor_hash(day, "203.0.113.7", "Mozilla/5.0 Test"), hash))

  # Neither secret is in the database, nor in any file of the data directory.
  expect_no_match(usage_dump(DB), secret, fixed = TRUE)
  expect_no_match(usage_dump(DB), usage_env$secret, fixed = TRUE)
  expect_no_match(usage_dump(DB), "203.0.113", fixed = TRUE)

  for (file in list.files(setup$REQ$CONFIG$data_dir, recursive = TRUE, full.names = TRUE)) {
    bytes <- readBin(file, "raw", n = file.size(file))
    expect_length(grepRaw(secret, bytes, fixed = TRUE), 0L)
  }
})


test_that("a tool call from an AI app is recorded with the mcp interface, the app and its outcome", {

  setup <- local_usage_setup()
  DB    <- setup$DB
  grant <- add_test_grant(DB, setup$users$ada, name = "Example Assistant")

  listed <- call_as(setup$app, grant$access_token, "list_projects")
  expect_false(isTRUE(listed$isError))

  # A tool that is refused: the answer is a 200 with isError, the record says denied.
  refused <- call_as(setup$app, grant$access_token, "describe_project", list(project = "nosuchkey"))
  expect_true(refused$isError)

  described <- call_as(setup$app, grant$access_token, "describe_function", list(`function` = "adiv_stats"))
  expect_false(isTRUE(described$isError))

  # Not tool calls: listed nowhere but in the count of requests.
  handle_request(mcp_as(grant$access_token, "tools/list"), setup$app)
  handle_request(mcp_as(NULL, "tools/list"), setup$app)

  events <- usage_rows(DB)

  expect_identical(events$kind, c("describe", "describe", "describe"))
  expect_identical(events$interface, rep("mcp", 3))
  expect_identical(events$app, rep("Example Assistant", 3))
  expect_identical(events$user_id, rep(setup$users$ada, 3))
  expect_identical(events$outcome[c(1, 3)], c("done", "done"))
  expect_true(events$outcome[[2]] %in% c("denied", "rejected"))
  expect_identical(events$fn, c(NA, NA, "adiv_stats"))
  expect_identical(events$area, c(NA, NA, "alpha"))

  expect_identical(sum(usage_rows(DB, "usage_requests")$requests), 5L)
  expect_no_match(usage_dump(DB), grant$access_token, fixed = TRUE)
  expect_no_match(usage_dump(DB), "nosuchkey", fixed = TRUE)
})


test_that("a failure to record never reaches the request", {

  setup <- local_usage_setup()
  read  <- local_log()
  local_mocked_bindings(
    call_handler = function (...) list(ok = TRUE),
    usage_write  = function (...) stop("the record is broken") )

  resp <- setup$post("/api/project/export", list(what = "metadata"), setup$sessions$ada)

  expect_identical(resp$status, 200L)
  expect_true(any(vapply(read(), function (e) identical(e$event, "usage_failed"), logical(1))))
})


test_that("the visitor's address comes from the proxy's header only when one is named", {

  request <- function (headers = character(0)) list(REMOTE_ADDR = "10.0.0.2", HEADERS = headers)

  expect_identical(request_address(request(c("x-real-ip" = "203.0.113.7"))), "10.0.0.2")
  expect_identical(request_address(request(c("x-real-ip" = "203.0.113.7")), list(client_ip_header = "X-Real-IP")), "203.0.113.7")
  expect_identical(request_address(request(), list(client_ip_header = "X-Real-IP")), "10.0.0.2")

  # A list of addresses: the last is the one the proxy added itself.
  forwarded <- list(client_ip_header = "X-Forwarded-For")
  expect_identical(request_address(request(c("x-forwarded-for" = "1.1.1.1, 198.51.100.4,203.0.113.9")), forwarded), "203.0.113.9")
  expect_identical(request_address(request(c("x-forwarded-for" = "2001:db8::7")), forwarded), "2001:db8::7")

  # Not an address: the connection's own.
  expect_identical(request_address(request(c("x-forwarded-for" = "unknown")), forwarded), "10.0.0.2")
  expect_identical(request_address(request(c("x-forwarded-for" = "<script>")), forwarded), "10.0.0.2")
  expect_identical(request_address(request(c("x-forwarded-for" = " , ")), forwarded), "10.0.0.2")

  # The address a session is stored with is the visitor's.
  setup <- local_usage_setup()
  setup$REQ$CONFIG$client_ip_header <- "X-Real-IP"
  req <- fake_request("POST", "/api/session/init", list())
  req$HTTP_HOST <- "localhost:8080"
  req$HEADERS   <- c("x-real-ip" = "203.0.113.50")
  expect_identical(handle_request(req, test_app(setup$REQ))$status, 200L)
  expect_true("203.0.113.50" %in% DBI::dbGetQuery(setup$DB, "SELECT ip_address FROM sessions")$ip_address)
})


#______________________________________________________________________________
# Roll-ups

# Three people over four days, an administrator, and a load test.
fill_usage <- function (DB) {

  add <- function (...) add_usage_event(DB, ...)

  # Person 101: active on two days, an account.
  add("2026-03-01 10:00:00", 101, "visit", is_account = TRUE)
  add("2026-03-01 10:01:00", 101, "plot", fn = "adiv_boxplot", queue_ms = 100, run_ms = 900, is_account = TRUE)
  add("2026-03-01 10:02:00", 101, "plot", fn = "adiv_boxplot", queue_ms = 300, run_ms = 700, is_account = TRUE)
  add("2026-03-01 10:03:00", 101, "plot", fn = "bdiv_ord_plot", outcome = "rejected", is_account = TRUE)
  add("2026-03-03 09:00:00", 101, "stats", fn = "taxa_stats", interface = "mcp", app = "Example Assistant", queue_ms = 20000, run_ms = 100, is_account = TRUE)

  # Person 102: looked on one day, active on the next.
  add("2026-03-01 23:59:59", 102, "visit")
  add("2026-03-02 00:00:00", 102, "upload", queue_ms = 2000, run_ms = 5000)
  add("2026-03-02 00:05:00", 102, "export", outcome = "busy")

  # Person 103: only ever looked.
  add("2026-03-04 12:00:00", 103, "visit")
  add("2026-03-04 12:00:05", 103, "table")

  # Not people.
  add("2026-03-01 08:00:00", 900, "plot", fn = "taxa_heatmap", class = "admin", queue_ms = 50, run_ms = 50, is_account = TRUE)
  add("2026-03-04 03:00:00", 901, "plot", fn = "taxa_heatmap", class = "loadtest", outcome = "timeout")

  arrive <- function (at, user_id, ...) db_insert(DB, "usage_arrivals", "TUse2", at_utc = at, user_id = user_id, class = "user", ...)

  arrive("2026-03-01 10:00:00", 101, ref_host = "github.com", ref_path = "/cmmr/rbiom", country = "US", network = "Example University")
  arrive("2026-03-03 09:00:00", 101, country = "DE", network = "Other Network")
  arrive("2026-03-01 23:59:59", 102, ref_host = "github.com", country = "BR")
  arrive("2026-03-04 12:00:00", 103)

  invisible(as.POSIXct("2026-03-04 18:00:00", tz = "UTC"))
}


test_that("the roll-ups match the raw rows", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  now <- fill_usage(DB)

  days <- usage_rollup(DB, now)
  expect_identical(days, c("2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04"))

  # Actions per day: the same total as the raw rows, split the same way.
  events  <- usage_rows(DB)
  actions <- usage_rows(DB, "usage_daily_actions")

  expect_identical(sum(actions$n), nrow(events))

  raw <- as.data.frame(table(day = substr(events$at_utc, 1, 10), kind = events$kind, outcome = events$outcome, class = events$class), stringsAsFactors = FALSE)
  raw <- raw[raw$Freq > 0, ]
  for (i in seq_len(nrow(raw))) {
    rolled <- sum(actions$n[actions$day == raw$day[[i]] & actions$kind == raw$kind[[i]] & actions$outcome == raw$outcome[[i]] & actions$class == raw$class[[i]]])
    expect_identical(rolled, raw$Freq[[i]], info = paste(raw[i, ], collapse = " "))
  }

  plots <- actions[actions$day == "2026-03-01" & actions$kind == "plot" & actions$class == "user", ]
  expect_identical(plots$n[plots$fn == "adiv_boxplot" & plots$outcome == "done"], 2L)
  expect_identical(plots$area[plots$fn == "bdiv_ord_plot"], "beta")

  # One row per person per day they were seen.
  days <- usage_rows(DB, "usage_person_days")
  days <- days[order(days$day, days$user_id), ]

  expect_identical(paste(days$day, days$user_id), c(
    "2026-03-01 101", "2026-03-01 102", "2026-03-01 900", "2026-03-02 102", "2026-03-03 101", "2026-03-04 103", "2026-03-04 901"))
  expect_identical(days$analyses, c(2L, 0L, 1L, 1L, 1L, 0L, 0L))
  expect_identical(days$actions,  c(3L, 1L, 1L, 1L, 1L, 2L, 0L))
  expect_identical(days$ui,       c(3L, 1L, 1L, 1L, 0L, 2L, 0L))
  expect_identical(days$mcp,      c(0L, 0L, 0L, 0L, 1L, 0L, 0L))
  expect_identical(days$class,    c("user", "user", "admin", "user", "user", "user", "loadtest"))

  # One row per person: first seen, and where their latest visit came from.
  people <- usage_rows(DB, "usage_people")
  people <- people[order(people$user_id), ]

  expect_identical(people$user_id, c(101L, 102L, 103L, 900L, 901L))
  expect_identical(people$first_day, c("2026-03-01", "2026-03-01", "2026-03-04", "2026-03-01", "2026-03-04"))
  expect_identical(people$country, c("DE", "BR", NA, NA, NA))
  expect_identical(people$network, c("Other Network", NA, NA, NA, NA))
  expect_identical(people$is_account, c(1L, 0L, 0L, 1L, 0L))

  # Visits per day.
  arrivals <- usage_rows(DB, "usage_daily_arrivals")
  expect_identical(sum(arrivals$n), 4L)
  expect_identical(sum(arrivals$n[arrivals$day == "2026-03-01" & arrivals$ref_host %in% "github.com"]), 2L)

  # The day as a whole: waiting times of every job, whoever ran it.
  daily <- usage_rows(DB, "usage_daily")
  first <- daily[daily$day == "2026-03-01", ]

  expect_identical(daily$day, c("2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04"))
  expect_identical(first$jobs, 3L)
  expect_equal(first$wait_median, stats::median(c(100, 300, 50)))
  expect_equal(first$wait_high, unname(stats::quantile(c(100, 300, 50), 0.95)))
  expect_identical(daily$waited_sec,  c(0L, 1L, 1L, 0L))
  expect_identical(daily$waited_long, c(0L, 0L, 1L, 0L))
  expect_identical(daily$busy,        c(0L, 1L, 0L, 0L))
  expect_identical(daily$timed_out,   c(0L, 0L, 0L, 1L))
  expect_true(is.na(daily$wait_median[[4]]))

  # Doing it again changes nothing.
  before <- lapply(usage_tables, function (table) usage_rows(DB, table))
  usage_rollup(DB, now)
  usage_rollup(DB, now + 3600)
  expect_identical(lapply(usage_tables, function (table) usage_rows(DB, table)), before)

  # A later event is picked up by the next run, on the day it belongs to.
  add_usage_event(DB, "2026-03-04 19:00:00", 103, "plot", fn = "rare_corrplot")
  usage_rollup(DB, now + 7200)
  days <- usage_rows(DB, "usage_person_days")
  expect_identical(days$analyses[days$day == "2026-03-04" & days$user_id == 103], 1L)

  # An empty database rolls up today, and nothing else.
  empty <- local_test_req()
  expect_identical(usage_rollup(empty$DB, now), "2026-03-04")
  expect_identical(usage_rows(empty$DB, "usage_daily")$day, "2026-03-04")
})


test_that("someone with an account is counted with their institution, not their provider", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  ada <- db_insert(DB, "users", "T1", full_name = "Ada", is_guest = FALSE, affiliation = "Analytical Engines", issuer = "https://auth.globus.org", sub = "s1")
  gus <- add_test_user(DB, "Guest 9", is_guest = TRUE)

  add_usage_event(DB, "2026-03-01 10:00:00", ada, "plot", is_account = TRUE)
  add_usage_event(DB, "2026-03-01 11:00:00", gus, "plot")
  usage_rollup(DB, as.POSIXct("2026-03-01 12:00:00", tz = "UTC"))

  people <- usage_rows(DB, "usage_people")
  expect_identical(people$affiliation[people$user_id == ada], "Analytical Engines")
  expect_false("provider" %in% names(people))
  expect_no_match(usage_dump(DB), "globus", fixed = TRUE)
  expect_true(is.na(people$affiliation[people$user_id == gus]))

  # Neither a name nor an email address is copied.
  expect_no_match(usage_dump(DB), "Ada", fixed = TRUE)
})


test_that("a guest who signs in is counted as one person", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  guest <- add_test_user(DB, "Guest 1", is_guest = TRUE)
  user  <- add_test_user(DB, "Ada")

  add_usage_event(DB, "2026-03-01 10:00:00", guest, "plot")
  add_usage_event(DB, "2026-03-02 10:00:00", guest, "plot")
  add_usage_event(DB, "2026-03-02 11:00:00", user,  "export", is_account = TRUE)
  db_insert(DB, "usage_arrivals", "T1", at_utc = "2026-03-01 10:00:00", user_id = guest, class = "user", country = "US")
  usage_rollup(DB, as.POSIXct("2026-03-02 12:00:00", tz = "UTC"))

  expect_identical(nrow(usage_rows(DB, "usage_people")), 2L)

  db_transaction(DB, adopt_guest(DB, guest, user))

  expect_true(all(usage_rows(DB)$user_id == user))
  expect_true(all(usage_rows(DB, "usage_arrivals")$user_id == user))

  days <- usage_rows(DB, "usage_person_days")
  days <- days[order(days$day), ]
  expect_identical(days$user_id, c(user, user))
  expect_identical(days$analyses, c(1L, 2L))
  expect_identical(days$is_account, c(1L, 1L))

  people <- usage_rows(DB, "usage_people")
  expect_identical(people$user_id, user)
  expect_identical(people$first_day, "2026-03-01")

  # The next roll-up agrees with what the merge left.
  usage_rollup(DB, as.POSIXct("2026-03-02 13:00:00", tz = "UTC"))
  expect_identical(usage_rows(DB, "usage_person_days")$user_id, c(user, user))

  report <- usage_report(DB, "2026-03-01", "2026-03-02")
  expect_identical(as.integer(report$summary$active), 1L)
})


#______________________________________________________________________________
# How long rows are kept

test_that("raw rows are deleted after the months they are kept, and the roll-ups stay", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  fill_usage(DB)

  now <- as.POSIXct("2026-03-04 18:00:00", tz = "UTC")
  usage_rollup(DB, now)

  visitor <- function (day, hash) db_insert(DB, "usage_visitors", "T1", day = day, visitor = hash, class = "anonymous", hits = 1L)
  visitor("2026-03-02", "aaaa")
  visitor("2026-03-03", "bbbb")
  visitor("2026-03-04", "cccc")

  rolled <- lapply(setdiff(usage_tables, c("usage_events", "usage_arrivals", "usage_visitors")), function (table) usage_rows(DB, table))

  # Within the time: only the visitors' hashes of before yesterday go.
  expect_identical(usage_expire(DB, 25L, now), 1L)
  expect_identical(usage_rows(DB, "usage_visitors")$visitor, c("bbbb", "cccc"))
  expect_identical(nrow(usage_rows(DB)), 12L)

  # 25 months on, to the day: rows of 2026-03-01 to 03 are older than the cutoff.
  later <- as.POSIXct("2028-04-04 00:30:00", tz = "UTC")
  expect_gt(usage_expire(DB, 25L, later), 0L)

  expect_identical(substr(usage_rows(DB)$at_utc, 1, 10), c("2026-03-04", "2026-03-04", "2026-03-04"))
  expect_identical(nrow(usage_rows(DB, "usage_arrivals")), 1L)
  expect_identical(nrow(usage_rows(DB, "usage_visitors")), 0L)

  # A day later nothing raw is left, and every roll-up is as it was.
  usage_expire(DB, 25L, later + 86400)
  expect_identical(nrow(usage_rows(DB)), 0L)
  expect_identical(nrow(usage_rows(DB, "usage_arrivals")), 0L)

  expect_identical(lapply(setdiff(usage_tables, c("usage_events", "usage_arrivals", "usage_visitors")), function (table) usage_rows(DB, table)), rolled)

  # A shorter time is honored.
  fill_usage(DB)
  usage_expire(DB, 1L, as.POSIXct("2026-04-03 12:00:00", tz = "UTC"))
  expect_identical(unique(substr(usage_rows(DB)$at_utc, 1, 10)), c("2026-03-03", "2026-03-04"))
})


test_that("the count of visitors without a session survives the deletion of their hashes", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  db_insert(DB, "usage_visitors", "T1", day = "2026-03-01", visitor = "aaaa", class = "anonymous", hits = 3L)
  db_insert(DB, "usage_visitors", "T2", day = "2026-03-01", visitor = "bbbb", class = "bot", hits = 7L)
  db_insert(DB, "usage_visitors", "T3", day = "2026-03-01", visitor = "cccc", class = "anonymous", hits = 1L, has_session = TRUE)

  usage_rollup(DB, as.POSIXct("2026-03-01 23:00:00", tz = "UTC"))
  day <- usage_rows(DB, "usage_daily")
  expect_identical(c(day$visitors, day$visitor_hits, day$bots, day$bot_hits), c(1L, 3L, 1L, 7L))

  # The server was down for a week; the first roll-up after it starts from that day.
  later <- as.POSIXct("2026-03-08 10:00:00", tz = "UTC")
  usage_expire(DB, 25L, later)
  usage_rollup(DB, later)

  day <- usage_rows(DB, "usage_daily")
  day <- day[day$day == "2026-03-01", ]
  expect_identical(c(day$visitors, day$visitor_hits, day$bots, day$bot_hits), c(1L, 3L, 1L, 7L))
  expect_identical(nrow(usage_rows(DB, "usage_daily")), 8L)
})


#______________________________________________________________________________
# Capacity samples

test_that("a sample notes how many cores were in use, peaks included", {

  REQ  <- local_test_req()
  DB   <- REQ$DB
  now  <- as.POSIXct("2026-03-01 10:15:00", tz = "UTC")
  pool <- new.env()

  # Cores granted to running jobs, out of the pool's budget.
  pool$cores <- 4L; pool$used <- 1L; pool$queue <- character(0); pool$peak_used <- 4L; pool$peak_queue <- 6L

  usage_sample(DB, REQ$CONFIG, pool, now)

  # The peaks start again from where the pool is now.
  expect_identical(pool$peak_used, 1L)
  expect_identical(pool$peak_queue, 0L)

  pool$used <- 3L; pool$queue <- c("a", "b")
  usage_sample(DB, REQ$CONFIG, pool, now + 60)
  usage_sample(DB, REQ$CONFIG, NULL, now + 3600)

  hours <- usage_rows(DB, "usage_hours")

  expect_identical(hours$hour, c("2026-03-01 10", "2026-03-01 11"))
  expect_identical(hours$samples,   c(2L, 1L))
  expect_identical(hours$workers,   c(4L, 0L))
  expect_identical(hours$busy_sum,  c(4L, 0L))
  expect_identical(hours$busy_max,  c(4L, 0L))
  expect_identical(hours$queue_max, c(6L, 0L))
  expect_true(all(hours$disk_used > 0))
})


test_that("the pool keeps its high marks between samples", {

  pool <- local_test_pool(workers = 1L)

  jobs <- lapply(1:3, function (i) pool_submit(pool, "eval", list(expr = quote(Sys.sleep(0.2)))))
  for (job in jobs) await(job)

  expect_identical(pool$busy, 0L)
  expect_identical(pool$used, 0L)
  expect_identical(pool$peak_used, 1L)
  expect_identical(pool$peak_queue, 2L)
})


test_that("the high mark counts cores, not jobs", {

  # One job that is told it may use both cores a pool of three has for jobs.
  pool <- local_test_pool(workers = 2L, cores = 3L, server = 1L)
  await(pool_submit(pool, "eval", list(expr = quote(Sys.sleep(0.2))), cpus = Inf))

  expect_identical(pool$used, 0L)
  expect_identical(pool$peak_used, 2L)

  usage_sample(local_test_req()$DB, list(data_dir = tempdir()), pool)
  expect_identical(pool$peak_used, 0L)
})


test_that("the timer samples, rolls up and can be stopped", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  add_usage_event(DB, sql_time(Sys.time()), 5L, "plot")

  stop_usage <- usage_start(list(db = DB, config = REQ$CONFIG, pool = NULL), interval = 0.05)

  expect_identical(nrow(usage_rows(DB, "usage_hours")), 1L)
  expect_identical(nrow(usage_rows(DB, "usage_person_days")), 1L)

  wait_until(function () sum(usage_rows(DB, "usage_hours")$samples) >= 3L, seconds = 10)
  stop_usage()

  n <- sum(usage_rows(DB, "usage_hours")$samples)
  expect_gte(n, 3L)
  later::run_now(timeoutSecs = 0.3)
  expect_identical(sum(usage_rows(DB, "usage_hours")$samples), n)
})


#______________________________________________________________________________
# Who may read the numbers

test_that("only an administrator gets the usage data", {

  setup <- local_usage_setup()
  DB    <- setup$DB

  status <- function (session) setup$post("/api/usage/data", list(), session)$status

  expect_identical(status(NULL), 401L)
  expect_identical(status(setup$sessions$guest), 403L)
  expect_identical(status(setup$sessions$ada), 403L)
  expect_identical(status(setup$sessions$admin), 200L)

  # A refusal says nothing of the numbers.
  refused <- setup$post("/api/usage/data", list(), setup$sessions$ada)
  expect_named(response_json(refused), "error")

  # No longer an administrator: no longer let in.
  DBI::dbExecute(DB, "UPDATE users SET is_admin = 0")
  expect_identical(status(setup$sessions$admin), 403L)

  # A GET, or the session key of someone else's tab with one's own cookie.
  request <- fake_request("GET", "/api/usage/data", session = setup$sessions$admin)
  request$HTTP_HOST <- "localhost:8080"
  expect_true(handle_request(request, setup$app)$status %in% c(404L, 405L))

  # An AI app has no tool that reads them.
  expect_false(any(grepl("usage", names(mcp_tool_table()))))
})


test_that("the browser is told whether use is recorded, and administrators are told apart", {

  setup <- local_usage_setup()

  request <- fake_request("POST", "/api/session/init", list())
  request$HTTP_HOST <- "localhost:8080"
  conf <- response_json(handle_request(request, setup$app))$CONF

  expect_true(conf$usage)
  expect_false(conf$is_admin)
  expect_identical(conf$usage_months, 25L)

  setup$REQ$CONFIG$usage_months <- 12L
  expect_identical(shared_server_conf(setup$REQ$CONFIG)$usage_months, jsonlite::unbox(12L))
})


test_that("the report answers for an empty database", {

  setup <- local_usage_setup()

  resp <- setup$post("/api/usage/data", list(), setup$sessions$admin)
  expect_identical(resp$status, 200L)

  data <- response_json(resp)

  expect_named(data, c("range", "reach", "repeats", "where", "what", "capacity", "classes", "summary"))
  expect_identical(data$reach$active$all, 0L)
  expect_identical(data$reach$by_month, list())
  expect_identical(data$where$countries, list())
  expect_identical(data$what$functions, list())
  expect_identical(data$capacity$verdict$state, "none")
  expect_identical(data$summary$active, 0L)
  expect_null(data$summary$wait_median)
  expect_false(data$range$lookup)
  expect_identical(data$range$usage_months, 25L)
  expect_length(data$classes, length(usage_classes))

  # The administrator's own request is counted apart.
  admin <- Filter(function (row) row$class == "admin", response_json(setup$post("/api/usage/data", list(), setup$sessions$admin))$classes)[[1]]
  expect_gte(admin$requests, 1L)
})


test_that("the range must be dates in order", {

  setup <- local_usage_setup()
  admin <- setup$sessions$admin

  ask <- function (...) setup$post("/api/usage/data", list(...), admin)

  expect_identical(ask(from = "2026-01-01", to = "2026-12-31")$status, 200L)
  expect_identical(response_json(ask(from = "2026-01-01", to = "2026-12-31"))$range$from, "2026-01-01")
  expect_identical(ask(from = "2026-12-31", to = "2026-01-01")$status, 400L)
  expect_identical(ask(from = "2026-13-45")$status, 400L)
  expect_identical(ask(from = "yesterday")$status, 400L)
  expect_identical(ask(from = "2026-01-01'; DROP TABLE users; --")$status, 400L)
  expect_identical(ask(from = "1990-01-01", to = "2026-01-01")$status, 400L)
  expect_identical(ask(nonsense = "1")$status, 400L)
})


test_that("the report counts people, leaves the others out, and says where and what", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  now <- fill_usage(DB)
  usage_rollup(DB, now)

  r <- usage_report(DB, "2026-03-01", "2026-03-04")

  # Reach: 101 and 102 were active; 103 only looked; 900 and 901 are not people.
  expect_identical(as.integer(r$reach$active$all), 2L)
  expect_identical(as.integer(r$reach$seen$all), 3L)
  expect_identical(as.integer(r$reach$active$d7), 2L)

  expect_identical(r$reach$by_day$day, c("2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04"))
  expect_identical(as.integer(r$reach$by_day$seen),   c(2L, 1L, 1L, 1L))
  expect_identical(as.integer(r$reach$by_day$active), c(1L, 1L, 1L, 0L))

  expect_identical(r$reach$by_week$week, c("2026-02-23", "2026-03-02"))
  expect_identical(as.integer(r$reach$by_week$active), c(1L, 2L))

  month <- r$reach$by_month
  expect_identical(month$month, "2026-03")
  expect_identical(as.integer(c(month$seen, month$active, month$accounts, month$fresh, month$returning, month$cumulative, month$browser, month$apps)),
    c(3L, 2L, 1L, 2L, 0L, 2L, 2L, 1L))

  # Repeat use.
  expect_identical(r$repeats$cohorts$cohort, "2026-03")
  expect_identical(as.integer(r$repeats$cohorts$n), 2L)
  expect_identical(as.integer(r$repeats$days_active$days),  c(1L, 2L))
  expect_identical(as.integer(r$repeats$days_active$users), c(1L, 1L))

  # Where from: active people only, by their latest visit.
  expect_identical(r$where$countries$name, c("BR", "DE"))
  expect_identical(as.integer(r$where$n_countries), 2L)
  expect_identical(r$where$networks$name, "Other Network")
  expect_identical(as.integer(r$where$visits), 4L)
  expect_identical(as.integer(r$where$referred), 2L)
  expect_identical(r$where$sites$name, "github.com")
  expect_identical(as.integer(r$where$sites$visits), 2L)
  expect_identical(r$where$pages$name, "github.com/cmmr/rbiom")

  # What for: what ran to the end, people only.
  fns <- r$what$functions
  expect_identical(fns$fn, c("adiv_boxplot", "taxa_stats"))
  expect_identical(as.integer(fns$n), c(2L, 1L))
  expect_identical(as.integer(fns$apps), c(0L, 1L))
  expect_identical(r$what$areas$area, c("alpha", "taxa"))
  expect_identical(as.integer(c(r$what$interfaces$browser, r$what$interfaces$apps)), c(3L, 1L))
  expect_identical(r$what$apps$name, "Example Assistant")
  expect_setequal(r$what$outcomes$outcome, c("done", "rejected", "busy"))

  # Capacity counts every job, the administrator's too.
  expect_identical(nrow(r$capacity$days), 4L)
  expect_identical(as.integer(sum(r$capacity$days$jobs)), 5L)
  expect_true("taxa_heatmap" %in% r$capacity$run_times$name)
  expect_identical(as.character(r$capacity$verdict$state), "ok")

  # Those left out, listed.
  classes <- r$classes
  expect_identical(classes$class, usage_classes)
  expect_identical(as.integer(classes$actions[classes$class == "user"]), 10L)
  expect_identical(as.integer(classes$actions[classes$class == "admin"]), 1L)
  expect_identical(as.integer(classes$people[classes$class == "loadtest"]), 1L)

  # The summary of the period.
  s <- lapply(r$summary, as.numeric)
  expect_identical(s$active, 2)
  expect_identical(s$accounts, 1)
  expect_identical(s$seen, 3)
  expect_identical(s$fresh, 2)
  expect_identical(s$came_back, 1)
  expect_identical(s$browser, 2)
  expect_identical(s$apps, 1)
  expect_identical(s$analyses, 4)
  expect_identical(s$plots, 2)
  expect_identical(s$stats, 1)
  expect_identical(s$uploads, 1)
  expect_identical(s$countries, 2)

  # A range that holds one day only.
  one <- usage_report(DB, "2026-03-03", "2026-03-03")
  expect_identical(as.integer(one$summary$active), 1L)
  expect_identical(as.integer(one$summary$fresh), 0L)
  expect_identical(as.integer(one$reach$active$all), 2L)

  # The whole thing can be sent.
  expect_silent(body <- response(r)$body)
  expect_true(jsonlite::validate(body))
})


test_that("the verdict follows the stated rule", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  day <- function (i, wait_high, busy = 0L, jobs = 10L)
    db_insert(DB, "usage_daily", "T1", day = format(as.Date("2026-03-01") + i), jobs = jobs, wait_median = 10, wait_high = wait_high, busy = busy)

  for (i in 0:9) day(i, wait_high = if (i < 3) 9000 else 200)

  verdict <- function () lapply(usage_report(DB, "2026-03-01", "2026-03-10")$capacity$verdict, as.vector)

  # Three slow days are within the rule; a fourth is not.
  expect_identical(verdict()$state, "ok")
  expect_identical(verdict()$slow_days, 3L)

  DBI::dbExecute(DB, "UPDATE usage_daily SET wait_high = 5001 WHERE day = '2026-03-08'")
  expect_identical(verdict()$state, "slow")

  DBI::dbExecute(DB, "UPDATE usage_daily SET wait_high = 100")
  DBI::dbExecute(DB, "UPDATE usage_daily SET busy = 2 WHERE day <= '2026-03-04'")
  expect_identical(verdict()$state, "full")

  # Days before the window do not count.
  expect_identical(lapply(usage_report(DB, "2026-04-01", "2026-04-20")$capacity$verdict, as.vector)$state, "none")
})


#______________________________________________________________________________
# The page

test_that("the Usage page is offered to administrators only, and the privacy text describes the record", {

  read <- function (...) paste(readLines(system.file("www", "js", ..., package = "atima"), encoding = "UTF-8", warn = FALSE), collapse = "\n")

  # The link is built only for an administrator of a server that records its use.
  main <- read("main.js")
  expect_match(main, "conf.is_admin && conf.usage ? navLink('#/usage', 'Usage'", fixed = TRUE)
  expect_match(main, "usage:    { show: usage.show }", fixed = TRUE)

  # The page itself shows nothing to anyone else, and asks the server once.
  page <- read("pages", "usage.js")
  expect_match(page, "conf.auth !== 'oidc' || !conf.usage || !conf.is_admin", fixed = TRUE)
  expect_identical(lengths(regmatches(page, gregexpr("call('/api/", page, fixed = TRUE))), 1L)
  expect_match(page, "call('/api/usage/data'", fixed = TRUE)

  # Charts are drawn here; no library and no other host.
  expect_no_match(read("charts.js"), "import .* from 'http|fetch[(]|XMLHttpRequest")

  # What the privacy page says is what is done: only where use is recorded,
  # for as long as the setting says, and with each thing recorded named.
  privacy <- read("pages", "privacy.js")
  expect_match(privacy, "conf.usage ? section('How use of this server is counted'", fixed = TRUE)
  expect_match(privacy, "conf.usage_months", fixed = TRUE)
  for (said in c("No cookie is set", "the number that stands for you", "country", "organisation that owns the network",
                 "page that linked you here", "sign-in provider names", "deleted after two days", "Only the administrators"))
    expect_match(privacy, said, fixed = TRUE, info = said)

  # The browser sends where it came from only when that is another site.
  api <- read("api.js")
  expect_match(api, "new URL(ref).origin === window.location.origin", fixed = TRUE)
})
