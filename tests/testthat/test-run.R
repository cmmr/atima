test_that("run() listens on loopback by default", {
  expect_identical(formals(run)$host, "127.0.0.1")
})


test_that("operator and contact are optional lines of text", {

  expect_null(formals(run)$operator)
  expect_null(formals(run)$contact)

  expect_null(text_setting(NULL, "operator"))
  expect_null(text_setting("", "operator"))
  expect_null(text_setting("   ", "operator"))
  expect_identical(text_setting("  the Example Lab at Example University ", "operator"), "the Example Lab at Example University")
  expect_identical(text_setting("help@example.org", "contact"), "help@example.org")
  expect_identical(text_setting("https://example.org/atima-help", "contact"), "https://example.org/atima-help")
  expect_identical(text_setting(strrep("x", 200), "contact"), strrep("x", 200))

  expect_error(text_setting("two\nlines", "operator"), "operator must be one line")
  expect_error(text_setting(strrep("x", 201), "contact"), "contact must be at most 200")
  expect_error(text_setting(c("a", "b"), "contact"), "single string")
  expect_error(text_setting(NA_character_, "contact"), "single string")
  expect_error(text_setting(5, "contact"), "single string")
})


test_that("run() reads operator and contact as it reads its other settings", {

  # A setting that cannot be used stops run() before it touches anything,
  # which shows where each value came from without starting a server.
  data_dir <- file.path(withr::local_tempdir(), "never-created")
  start    <- function (...) suppressMessages(run(data_dir = data_dir, open = FALSE, ...))

  expect_error(start(operator = "two\nlines"), "operator must be one line")
  expect_error(start(contact = strrep("x", 201)), "contact must be at most 200")
  expect_error(start(contact = c("a@example.org", "b@example.org")), "contact must be a single value")

  withr::with_envvar(c(ATIMA_OPERATOR = "two\nlines"), expect_error(start(), "operator must be one line"))
  withr::with_envvar(c(ATIMA_CONTACT = strrep("x", 201)), expect_error(start(), "contact must be at most 200"))
  withr::with_options(list(atima.contact = strrep("x", 201)), expect_error(start(), "contact must be at most 200"))

  # The argument comes before the environment variable. (This one gets as
  # far as the next check, and stops there.)
  withr::with_envvar(c(ATIMA_OPERATOR = "two\nlines"), {
    expect_error(start(operator = "the Example Lab", host = "0.0.0.0"), 'auth = "none" has no accounts')
  })

  expect_false(dir.exists(data_dir))
})


test_that("local_url gives an address a browser can open", {

  expect_identical(local_url("127.0.0.1", 8080L), "http://127.0.0.1:8080")
  expect_identical(local_url("0.0.0.0",   8080L), "http://127.0.0.1:8080")
  expect_identical(local_url("localhost", 80L),   "http://localhost:80")
  expect_identical(local_url("10.1.2.3",  8080),  "http://10.1.2.3:8080")

  # IPv6
  expect_identical(local_url("::",    8080L), "http://[::1]:8080")
  expect_identical(local_url("::1",   8080L), "http://[::1]:8080")
  expect_identical(local_url("[::1]", 8080L), "http://[::1]:8080")
})


test_that("browsers are told to check the app's files before reusing them", {

  # Found in the browser (step 7): with no Cache-Control header, a changed
  # script kept being served from the browser's cache.
  paths <- static_paths(tempdir())

  expect_named(paths, c("/www", "/tmp"))
  expect_identical(paths[["/www"]]$options$headers[["Cache-Control"]], "no-cache")
  expect_true(file.exists(file.path(paths[["/www"]]$path, "index.html")))
  expect_identical(normalizePath(paths[["/tmp"]]$path), normalizePath(tempdir()))
})


test_that("an interrupt inside a callback of the event loop stops the server", {

  # The interrupt ends the callback only; interruptible() notes the request.
  shutdown$requested <- FALSE
  withr::defer(shutdown$requested <- FALSE)

  expect_identical(interruptible("done", "cut off"), "done")
  expect_false(shutdown$requested)

  expect_identical(interruptible(rlang::interrupt(), "cut off"), "cut off")
  expect_true(shutdown$requested)

  expect_identical(stopping_response()$status, 503L)
  expect_match(stopping_response()$body, "shutting down")

  # serve() answers requests until a callback is interrupted, then returns.
  skip_on_cran()
  shutdown$requested <- FALSE
  port  <- httpuv::randomPort()
  calls <- 0L
  app   <- list(call = function (req) interruptible({
    calls <<- calls + 1L
    if (calls == 2L) rlang::interrupt()
    list(status = 200L, headers = list('Content-Type' = "text/plain"), body = "ok")
  }, list(status = 503L, headers = list('Content-Type' = "text/plain"), body = "stopping")))

  answers <- character(0)
  get     <- function () curl::curl_fetch_multi(
    sprintf("http://127.0.0.1:%d/", port),
    done = function (res) answers <<- c(answers, rawToChar(res$content)),
    fail = function (msg) answers <<- c(answers, "failed") )

  later::later(get, 0.2)
  later::later(get, 0.6)
  poll <- function () { curl::multi_run(timeout = 0, poll = TRUE); if (length(answers) < 2) later::later(poll, 0.05) }
  later::later(poll, 0.25)

  started <- Sys.time()
  serve("127.0.0.1", port, app)

  expect_lt(as.numeric(difftime(Sys.time(), started, units = "secs")), 10)
  expect_true(shutdown$requested)
  expect_identical(calls, 2L)
  expect_identical(answers[[1]], "ok")
})
