test_that("handle_post_request only dispatches to api_ functions that exist", {

  local_mocked_bindings(resume_session = function (REQ, ...) invisible())

  req <- function (path, args = list())
    as.environment(list(PATH = path, ARGS = args, CONFIG = list(data_dir = tempdir(), cache_size = 1)))

  expect_error(handle_post_request(req("/HMP50/full.json")), "Not an API path")
  expect_error(handle_post_request(req("/api")),             "Not an API path")
  expect_error(handle_post_request(req("/api/")),            "Not an API path")
  expect_error(handle_post_request(req(NULL)),               "Not an API path")

  # Functions removed as dead code are no longer reachable.
  expect_error(handle_post_request(req("/api/get")),      "API function does not exist: api_get")
  expect_error(handle_post_request(req("/api/db_query")), "API function does not exist")
})


test_that("handle_post_request rejects arguments the function does not take", {

  local_mocked_bindings(
    resume_session = function (REQ, ...) invisible(),
    api_heartbeat  = function (REQ) list(ok = TRUE) )

  req <- function (args)
    as.environment(list(PATH = "/api/heartbeat", ARGS = args, CONFIG = list(data_dir = tempdir(), cache_size = 1)))

  expect_identical(handle_post_request(req(list())), list(ok = TRUE))
  expect_error(handle_post_request(req(list(DB = "x"))),      "isn't needed by api_heartbeat")
  expect_error(handle_post_request(req(list(user_id = "1"))), "isn't needed by api_heartbeat")
})
