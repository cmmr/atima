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
