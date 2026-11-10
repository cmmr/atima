# Errors: the browser gets a short message and an id; the details go to the
# server log.


# Send the server log to a file for the rest of the calling test, and return
# a function that reads it back as a list of entries.
local_log <- function (env = parent.frame()) {
  file <- withr::local_tempfile(.local_envir = env)
  withr::local_options(atima.log = file, .local_envir = env)
  function () {
    if (!file.exists(file)) return (list())
    lapply(readLines(file), jsonlite::fromJSON, simplifyVector = FALSE)
  }
}

log_errors <- function (entries) Filter(function (e) e$event == "error", entries)


test_that("log_event writes one JSON object per line", {

  read_log <- local_log()

  log_event("info", "first", n = 1L, text = "two\nlines", missing = NULL)
  log_event("warn", "second", nested = list(a = 1, b = "x"), when = Sys.time())

  entries <- read_log()
  expect_length(entries, 2)

  expect_named(entries[[1]], c("time", "level", "event", "n", "text"))
  expect_identical(entries[[1]]$level, "info")
  expect_identical(entries[[1]]$event, "first")
  expect_identical(entries[[1]]$n, 1L)
  expect_identical(entries[[1]]$text, "two\nlines")
  expect_match(entries[[1]]$time, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$")

  expect_identical(entries[[2]]$nested, list(a = 1L, b = "x"))
})


test_that("an expected error is shown to the user with its own status", {

  read_log <- local_log()

  err  <- tryCatch(stop_forbidden("You cannot ", "do that."), error = identity)
  resp <- error_response(err)

  expect_s3_class(resp, "response")
  expect_identical(resp$status, 403L)
  expect_match(resp$headers[['Content-Type']], "application/json")

  body <- response_json(resp)
  expect_named(body, "error")
  expect_named(body$error, c("message", "id"))
  expect_identical(body$error$message, "You cannot do that.")
  expect_match(body$error$id, "^[A-Za-z0-9]{8}$")

  # The same id is in the log.
  entry <- log_errors(read_log())[[1]]
  expect_identical(entry$id, body$error$id)
  expect_identical(entry$status, 403L)
  expect_identical(entry$level, "info")
})


test_that("the stop_ shorthands set the right status", {

  status <- function (code) tryCatch(code, error = function (e) e$status)

  expect_identical(status(stop_user("x")),         400L)
  expect_identical(status(stop_unauthorized("x")), 401L)
  expect_identical(status(stop_forbidden("x")),    403L)
  expect_identical(status(stop_not_found("x")),    404L)
  expect_identical(status(stop_http(409, "x")),    409L)
})


test_that("an unexpected error tells the browser nothing", {

  read_log <- local_log()

  err  <- tryCatch(stop("object 'secret_internal_name' not found"), error = identity)
  resp <- error_response(err)
  body <- response_json(resp)

  expect_identical(resp$status, 500L)
  expect_named(body$error, c("message", "id"))
  expect_no_match(resp$body, "secret_internal_name")
  expect_match(body$error$message, "^Internal error")

  entry <- log_errors(read_log())[[1]]
  expect_identical(entry$id, body$error$id)
  expect_identical(entry$level, "error")
  expect_match(entry$message, "secret_internal_name")
})


test_that("a database error reaches the log, not the browser", {

  setup_req <- local_test_req()
  read_log  <- local_log()

  local_mocked_bindings(api_heartbeat = function (REQ) {
    db_query(REQ$DB, "SELECT no_such_column FROM users WHERE email = ?", "Leak1", list("ada@example.org"))
  })

  ada     <- add_test_user(setup_req$DB, "Ada Lovelace")
  project <- add_test_project(setup_req$DB, ada)$project_id
  session <- add_test_session(setup_req$DB, ada, project)

  resp <- handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), test_app(setup_req))
  body <- response_json(resp)

  expect_identical(resp$status, 500L)
  expect_named(body, "error")
  expect_named(body$error, c("message", "id"))

  # Nothing about the query is in the response.
  for (leak in c("SELECT", "no_such_column", "users", "ada@example.org", "Leak1", "db_query", "api_heartbeat"))
    expect_no_match(resp$body, leak, fixed = TRUE)

  # All of it is in the log, under the id the browser was given.
  entry <- log_errors(read_log())[[1]]
  expect_identical(entry$id, body$error$id)
  expect_identical(entry$status, 500L)
  expect_identical(entry$err_code, "Leak1")
  expect_identical(entry$sql, "SELECT no_such_column FROM users WHERE email = ?")
  expect_identical(entry$params, list("ada@example.org"))
  expect_match(entry$detail, "no_such_column")
  expect_identical(entry$method, "POST")
  expect_identical(entry$path, "/api/session/heartbeat")
  expect_identical(entry$user_id, ada)
  expect_true(any(grepl("db_query", unlist(entry$calls))))
})


test_that("validation and permission failures are short messages with an id", {

  setup_req <- local_test_req()
  read_log  <- local_log()
  app       <- test_app(setup_req)

  ada     <- add_test_user(setup_req$DB, "Ada Lovelace")
  project <- add_test_project(setup_req$DB, ada, is_editor = FALSE)$project_id
  session <- add_test_session(setup_req$DB, ada, project)

  cases <- list(
    list(req = fake_request("POST", "/api/no/such/route"),                                    status = 404L),
    list(req = fake_request("POST", "/api/session/heartbeat"),                                status = 401L),
    list(req = fake_request("POST", "/api/project/rarefy", list(depth = -1), session),        status = 400L),
    list(req = fake_request("POST", "/api/project/save", list(), session),                    status = 403L),
    list(req = fake_request("POST", "/api/plot", list(plot_fn = "system", plot_args = list(), depth = 10), session), status = 400L) )

  for (case in cases) {
    resp <- handle_request(case$req, app)
    body <- response_json(resp)
    expect_identical(resp$status, case$status, info = case$req$PATH_INFO)
    expect_named(body$error, c("message", "id"), info = case$req$PATH_INFO)
    expect_lt(nchar(body$error$message), 100)
  }

  expect_length(log_errors(read_log()), length(cases))
})


test_that("every request is logged with its route, status and user", {

  setup_req <- local_test_req()
  read_log  <- local_log()
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  ada     <- add_test_user(setup_req$DB, "Ada Lovelace")
  project <- add_test_project(setup_req$DB, ada)$project_id
  session <- add_test_session(setup_req$DB, ada, project)

  handle_request(fake_request("GET", "/some-secret-key/rare.json"), test_app(setup_req))
  handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), test_app(setup_req))

  entries <- Filter(function (e) e$event == "request", read_log())
  expect_length(entries, 2)

  # The route pattern is logged, not the path, so access keys stay out of the log.
  expect_identical(entries[[1]]$path, "/:access_key/:file")
  expect_identical(entries[[1]]$status, 200L)
  expect_null(entries[[1]]$user_id)

  expect_identical(entries[[2]]$path, "/api/session/heartbeat")
  expect_identical(entries[[2]]$user_id, ada)
  expect_true(is.numeric(entries[[2]]$ms))
})


test_that("with_user_errors turns a failure into a message for the user", {

  read_log <- local_log()

  expect_identical(with_user_errors("Never shown.", 1 + 1), 2)

  # rbiom's own message is passed on, without terminal colour codes.
  err <- expect_error(
    with_user_errors("The plot could not be made.", stop("\033[31mInvalid `md` option(s)\033[39m: Nope")),
    class = "atima_http_error" )
  expect_identical(err$status, 400L)
  expect_identical(conditionMessage(err), "The plot could not be made. Invalid `md` option(s): Nope")

  # With detail = FALSE the original message is logged, not shown.
  err <- expect_error(
    with_user_errors("That file could not be read.", detail = FALSE, stop("cannot open C:/server/path/x.biom")),
    class = "atima_http_error" )
  expect_identical(conditionMessage(err), "That file could not be read.")
  expect_match(read_log()[[1]]$detail, "C:/server/path/x.biom", fixed = TRUE)

  # An error that already has a status keeps it.
  err <- expect_error(with_user_errors("Never shown.", stop_forbidden("No.")), class = "atima_http_error")
  expect_identical(err$status, 403L)
  expect_identical(conditionMessage(err), "No.")
})
