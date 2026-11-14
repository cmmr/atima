# Requests whose work goes to worker processes: handle_request() answers
# with a promise, the server stays responsive, and superseded, cancelled and
# overdue requests get their status codes.


pool <- local_test_pool(workers = 2L, time_limit = 60, grace = 1)

# A database with a user, a project and a session, served through the pool.
local_async_app <- function (env = parent.frame()) {
  REQ     <- local_test_req(env)
  user    <- add_test_user(REQ$DB, "Ada Lovelace")
  project <- add_test_project(REQ$DB, user)$project_id
  list(
    REQ     = REQ,
    DB      = REQ$DB,
    app     = test_app(REQ, pool),
    user    = user,
    project = project,
    session = add_test_session(REQ$DB, user, project) )
}

# The response a request ends in, whether or not it went through a worker.
response_of <- function (x) {
  if (inherits(x, "response")) return (x)
  result <- await(x)
  if (!is.null(result$error)) stop("handle_request() rejected its promise")
  result$value
}

# Make the handlers of these routes return the given jobs instead.
local_handlers <- function (handlers, env = parent.frame()) {
  real <- call_handler
  local_mocked_bindings(.env = env, call_handler = function (route, REQ, args) {
    handler <- handlers[[route$path]]
    if (is.null(handler)) real(route, REQ, args) else handler(REQ, args)
  })
}

pool_idle <- function () wait_until(function () pool$busy == 0L && length(pool$jobs) == 0L)


test_that("a compute request is answered through a worker with a promise", {

  s <- local_async_app()

  local_handlers(list(
    "/api/project/rarefy" = function (REQ, args) eval_job(
      expr   = bquote(list(pid = Sys.getpid(), depth = .(args$depth))),
      finish = function (result) list(pid = unbox(result$pid), depth = unbox(result$depth), user = unbox(REQ$SESSION$user_id)) )))

  out <- handle_request(fake_request("POST", "/api/project/rarefy", list(depth = 123), s$session), s$app)
  expect_true(promises::is.promise(out))

  resp <- response_of(out)
  expect_s3_class(resp, "response")
  expect_identical(resp$status, 200L)

  body <- response_json(resp)
  expect_identical(body$depth, 123L)
  expect_identical(body$user, s$user)
  expect_false(identical(body$pid, Sys.getpid()))

  # A fast route never becomes a promise.
  expect_s3_class(handle_request(fake_request("POST", "/api/session/heartbeat", list(), s$session), s$app), "response")
})


test_that("no transaction is open while a job runs, and each half is all-or-nothing", {

  s     <- local_async_app()
  title <- function () db_query(s$DB, "SELECT title FROM projects WHERE project_id = ?", "T1", list(s$project))
  set   <- function (REQ, value) db_query(REQ$DB, "UPDATE projects SET title = ? WHERE project_id = ?", "T2", list(value, s$project))

  local_handlers(list(
    "/api/project/rarefy" = function (REQ, args) {
      set(REQ, "set by prepare")
      eval_job(quote({ Sys.sleep(1); "ok" }), finish = function (result) {
        set(REQ, "set by finish")
        if (args$depth == 2) stop("finish failed")
        list()
      })
    }))

  out <- handle_request(fake_request("POST", "/api/project/rarefy", list(depth = 1), s$session), s$app)

  # The handler's work is committed and visible to a second connection
  # while the job is still running; another connection can write, too.
  other <- DBI::dbConnect(RSQLite::SQLite(), file.path(s$REQ$CONFIG$data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(other))
  expect_identical(DBI::dbGetQuery(other, "SELECT title FROM projects")[[1]], "set by prepare")
  expect_identical(DBI::dbExecute(other, "UPDATE users SET affiliation = 'elsewhere'"), 1L)

  expect_identical(response_of(out)$status, 200L)
  expect_identical(title(), "set by finish")

  # A finish step that fails changes nothing, and the handler's own work stays.
  set(s$REQ, "before")
  resp <- response_of(handle_request(fake_request("POST", "/api/project/rarefy", list(depth = 2), s$session), s$app))
  expect_identical(resp$status, 500L)
  expect_identical(title(), "set by prepare")
})


test_that("a new request to a superseding route cancels the session's running one", {

  s      <- local_async_app()
  marker <- withr::local_tempfile()

  local_handlers(list(
    "/api/plot" = function (REQ, args) eval_job(
      expr   = if (args$depth == 1) bquote(local({ on.exit(writeLines("stopped", .(marker))); writeLines("running", .(marker)); Sys.sleep(30) })) else quote("drawn"),
      finish = function (result) list(result = unbox(result)) ),
    "/api/project/export" = function (REQ, args) eval_job(quote({ Sys.sleep(1); "exported" }), function (result) list(result = unbox(result))) ))

  plot <- function (depth, session = s$session) handle_request(
    fake_request("POST", "/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = depth), session), s$app )

  first  <- plot(1)
  expect_true(wait_until(function () length(list.files(pool$marker_dir)) == 1L))
  expect_true(wait_until(function () file.exists(marker)))   # it is running, not just handed over

  # Another session's plot, and this session's export, are left alone.
  other_session <- add_test_session(s$DB, s$user, s$project)
  theirs <- handle_request(fake_request("POST", "/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 3), other_session), s$app)
  export <- handle_request(fake_request("POST", "/api/project/export", list(what = "metadata"), s$session), s$app)

  second <- plot(2)

  resp <- response_of(first)
  expect_identical(resp$status, 409L)
  expect_named(response_json(resp)$error, c("message", "id"))
  expect_match(response_json(resp)$error$message, "replaced by a newer one")

  expect_identical(response_json(response_of(second))$result, "drawn")
  expect_identical(response_json(response_of(theirs))$result, "drawn")
  expect_identical(response_json(response_of(export))$result, "exported")

  # The superseded job was really stopped.
  expect_true(pool_idle())
  expect_identical(readLines(marker), "stopped")
})


test_that("/api/session/abort cancels the session's jobs", {

  s <- local_async_app()

  local_handlers(list(
    "/api/plot"           = function (REQ, args) eval_job(quote(Sys.sleep(30))),
    "/api/project/export" = function (REQ, args) eval_job(quote(Sys.sleep(30))) ))

  plot   <- handle_request(fake_request("POST", "/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1), s$session), s$app)
  export <- handle_request(fake_request("POST", "/api/project/export", list(what = "metadata"), s$session), s$app)

  resp <- handle_request(fake_request("POST", "/api/session/abort", list(), s$session), s$app)
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$cancelled, 2L)

  expect_identical(response_of(plot)$status, 409L)
  expect_identical(response_of(export)$status, 409L)
  expect_true(pool_idle())

  # With nothing running, and with no pool, it is a harmless no-op.
  expect_identical(response_json(handle_request(fake_request("POST", "/api/session/abort", list(), s$session), s$app))$cancelled, 0L)
  expect_identical(response_json(handle_request(fake_request("POST", "/api/session/abort", list(), s$session), test_app(s$REQ)))$cancelled, 0L)
})


test_that("a request over the time limit is answered 504, a crashed worker 500", {

  s        <- local_async_app()
  log_file <- withr::local_tempfile()
  withr::local_options(atima.log = log_file)

  withr::defer(pool$time_limit <- 60)
  pool$time_limit <- 4

  local_handlers(list(
    "/api/project/export" = function (REQ, args) eval_job(switch(
      args$what,
      metadata = quote(Sys.sleep(30)),
      taxonomy = quote(quit(save = "no")),
      tree     = quote(stop("a secret internal detail")) ))))

  export <- function (what) response_of(handle_request(fake_request("POST", "/api/project/export", list(what = what), s$session), s$app))

  resp <- export("metadata")
  expect_identical(resp$status, 504L)
  expect_match(response_json(resp)$error$message, "longer than the 4 seconds allowed")

  resp <- export("taxonomy")
  expect_identical(resp$status, 500L)
  expect_match(response_json(resp)$error$message, "^Internal error")

  resp <- export("tree")
  expect_identical(resp$status, 500L)
  expect_no_match(resp$body, "secret")

  # The details are in the log under the id the browser was given.
  entries <- lapply(readLines(log_file), jsonlite::fromJSON, simplifyVector = FALSE)
  entry   <- Filter(function (e) identical(e$id, response_json(resp)$error$id), entries)[[1]]
  expect_match(entry$detail, "a secret internal detail")

  expect_true(pool_idle())
  expect_true(wait_until(function () mirai::status(.compute = pool$profile)$connections == 2L))
})


test_that("a job's result is dropped if the session moved to another project meanwhile", {

  s <- local_async_app()

  local_handlers(list(
    "/api/project/rarefy" = function (REQ, args) eval_job(quote({ Sys.sleep(1); "late" }), function (result) stop("finish ran"))))

  out <- handle_request(fake_request("POST", "/api/project/rarefy", list(depth = 1), s$session), s$app)

  # Meanwhile the session opens a different project.
  other <- add_test_project(s$DB, s$user)$project_id
  db_query(s$DB, "UPDATE sessions SET draft_id = ? WHERE session_id = ?", "T1", list(create_draft(s$DB, other), s$session$session_id))

  resp <- response_of(out)
  expect_identical(resp$status, 409L)
  expect_match(response_json(resp)$error$message, "project changed")

  # And if the session is gone altogether, the answer is 401.
  out <- handle_request(fake_request("POST", "/api/project/rarefy", list(depth = 1), s$session), s$app)
  db_query(s$DB, "DELETE FROM sessions WHERE session_id = ?", "T2", list(s$session$session_id))
  expect_identical(response_of(out)$status, 401L)
})


test_that("real routes give the same answers through workers as in-process", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req()
  db_seed(REQ$DB, REQ$CONFIG, pool)
  app <- test_app(REQ, pool)

  # Seeding went through a worker and filled the content-addressed store.
  files <- db_query(REQ$DB, "SELECT file, hash FROM biom_files", "T1")
  expect_identical(nrow(files), 6L)
  expect_true(all(files$file == paste0(files$hash, ".biom")))
  expect_setequal(list.files(file.path(REQ$CONFIG$data_dir, "files")), files$file)

  resp <- response_of(handle_request(fake_request("POST", "/api/session/init", list()), app))
  expect_identical(resp$status, 200L)
  session <- list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )
  expect_identical(response_json(resp)$BIOM$depth, 1183L)

  post <- function (path, args = list()) response_of(handle_request(fake_request("POST", path, args, session), app))

  resp <- post("/api/plot", list(plot_fn = "bdiv_ord_plot", plot_args = list(bdiv = "Bray-Curtis"), depth = 1183, attrs = TRUE, save_args = list(width = 1600, height = 1200)))
  expect_identical(resp$status, 200L)
  image <- file.path(REQ$CONFIG$temp_dir, sub("^/tmp/", "", response_json(resp)$image_url))
  expect_identical(readBin(image, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)))

  # A function rbiom 4 added, checked against the schema in this process
  # and drawn in a worker; a bad option never gets that far.
  resp <- post("/api/plot", list(plot_fn = "taxa_forest", plot_args = list(stat.by = "Sex", rank = "Genus"), depth = 1183, attrs = TRUE))
  expect_identical(resp$status, 200L)
  expect_match(response_json(resp)$code$stats, "taxa_da")

  resp <- post("/api/plot", list(plot_fn = "taxa_forest", plot_args = list(stat.by = "Sex", cpus = 64), depth = 1183))
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "option 'cpus'")

  resp <- post("/api/project/rarefy", list(depth = 2000))
  expect_identical(response_json(resp)$BIOM$depth, 2000L)

  expect_identical(response_json(post("/api/metadata/table", list(length = 5)))$recordsTotal, 50L)

  resp <- response_of(handle_request(fake_request("GET", paste0("/unsaved/", session$session_key, "/rare.json")), app))
  expect_identical(resp$status, 200L)
  expect_type(resp$body, "raw")

  # Both caches were used by the workers, each in its own directory.
  cache_dir <- file.path(REQ$CONFIG$data_dir, "cache")
  expect_setequal(list.dirs(cache_dir, full.names = FALSE, recursive = FALSE), c("atima", "rbiom"))
  expect_true(any(grepl("^biom_[0-9a-f]{64}\\.rds$", list.files(file.path(cache_dir, "atima")))))
  expect_gt(length(list.files(file.path(cache_dir, "rbiom"))), 0)
  expect_length(list.files(cache_dir, pattern = "\\.tmp$", recursive = TRUE), 0)
})


test_that("the heartbeat is answered promptly over HTTP while a slow job runs", {

  skip_if_not_installed("curl")

  s <- local_async_app()

  local_handlers(list(
    "/api/project/rarefy" = function (REQ, args) eval_job(quote({ Sys.sleep(5); "slow" }), function (result) list(result = unbox(result)))))

  server <- httpuv::startServer("127.0.0.1", httpuv::randomPort(), list(call = function (req) handle_request(req, s$app)))
  withr::defer(httpuv::stopServer(server))

  # Two browsers' worth of requests, each sent from a process of its own so
  # that this process is free to be the server. Each returns, per request,
  # its status, when it was answered and how long that took.
  client <- function (path, body, n) mirai::mirai(
    .expr = lapply(seq_len(n), function (i) {
      handle <- curl::new_handle(post = TRUE, postfields = body)
      curl::handle_setheaders(handle, "Content-Type" = "application/json", "Cookie" = cookie, "x-session-key" = key)
      sent <- Sys.time()
      res  <- curl::curl_fetch_memory(paste0(base, path), handle)
      list(status = res$status_code, answered = Sys.time(), seconds = as.numeric(difftime(Sys.time(), sent, units = "secs")), body = rawToChar(res$content))
    }),
    .args = list(
      path = path, body = body, n = n,
      base   = paste0("http://127.0.0.1:", server$getPort()),
      cookie = paste0("auth_token=", s$session$auth_token),
      key    = s$session$session_key ))

  slow <- client("/api/project/rarefy", '{"depth": 1}', 1)
  expect_true(wait_until(function () pool$busy == 1L))

  beats <- client("/api/session/heartbeat", "{}", 5)
  expect_true(wait_until(function () !mirai::unresolved(beats) && !mirai::unresolved(slow), seconds = 60))

  slow  <- slow$data[[1]]
  beats <- beats$data

  expect_identical(slow$status, 200L)
  expect_identical(jsonlite::fromJSON(slow$body)$result, "slow")
  expect_gte(slow$seconds, 4.5)

  # All five heartbeats were answered while the slow request was still
  # waiting for its worker, each in a fraction of the job's five seconds.
  expect_identical(vapply(beats, function (b) b$status, 1L), rep(200L, 5))
  expect_lt(max(vapply(beats, function (b) b$seconds, 1)), 1)
  expect_true(all(vapply(beats, function (b) b$answered < slow$answered, NA)))
})


test_that("a user with too many jobs at once is told to wait, and others are served", {

  s <- local_async_app()

  pool$max_user <- 2
  withr::defer(pool$max_user <- Inf)

  local_handlers(list(
    "/api/project/export" = function (REQ, args) eval_job(quote({ Sys.sleep(1); "exported" }), function (result) list(result = unbox(result))) ))

  export <- function (session) handle_request(fake_request("POST", "/api/project/export", list(what = "metadata"), session), s$app)

  # The same person in two tabs is one user.
  other_tab <- add_test_session(s$DB, s$user, s$project)
  first     <- export(s$session)
  second    <- export(other_tab)
  third     <- export(s$session)

  resp <- response_of(third)
  expect_identical(resp$status, 429L)
  expect_named(response_json(resp)$error, c("message", "id"))
  expect_match(response_json(resp)$error$message, "Too many of your requests")

  # Somebody else is not affected.
  them    <- add_test_user(s$DB, "Grace Hopper")
  grant   <- db_insert(s$DB, "permissions", "T1", user_id = them, project_id = s$project, is_editor = FALSE)
  theirs  <- export(add_test_session(s$DB, them, s$project))

  expect_identical(response_json(response_of(first))$result,  "exported")
  expect_identical(response_json(response_of(second))$result, "exported")
  expect_identical(response_json(response_of(theirs))$result, "exported")

  # With those done there is room again.
  expect_identical(response_of(export(s$session))$status, 200L)
  expect_true(pool_idle())
})
