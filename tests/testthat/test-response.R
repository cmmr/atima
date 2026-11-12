test_that("response() encodes lists as JSON and text as HTML", {

  resp <- response(list(a = jsonlite::unbox(1L), b = NULL))
  expect_s3_class(resp, c("response", "AsIs"))
  expect_identical(resp$status, 200L)
  expect_identical(resp$body, '{"a":1,"b":null}')
  expect_identical(resp$headers[["Content-Type"]], "application/json; charset=utf-8")

  resp <- response(c("<p>", "hi", "</p>"))
  expect_identical(resp$body, "<p>hi</p>")
  expect_identical(resp$headers[["Content-Type"]], "text/html; charset=utf-8")
})


test_that("response() fills in the reason phrase when there is no body", {

  expect_identical(response(404L)$status, 404L)
  expect_identical(response(404L)$body,   "Not Found")
  expect_identical(response("Slow down", 429L)$body, "Slow down")

  expect_error(response("x", 99L))
  expect_error(response("x", 600L))
  expect_error(response(Sys.Date()), "must be a list, character, json, or NULL")
})


test_that("response() accepts header objects in any position", {

  token <- "abc123"
  resp  <- response(
    list(),
    cookie(token, max_age = Inf, http_only = TRUE),
    header("x-session-key" = "12abcdefgh", expose = TRUE) )

  expect_identical(resp$status, 200L)
  expect_identical(resp$headers[["Set-Cookie"]], "token=abc123; Max-Age=34560000; SameSite=Lax; HttpOnly")
  expect_identical(resp$headers[["x-session-key"]], "12abcdefgh")
  expect_identical(resp$headers[["Access-Control-Expose-Headers"]], "x-session-key")

  # An explicit content type is kept.
  resp <- response(status = 200L, body = "x", headers = list("Content-Type" = "text/plain"))
  expect_identical(resp$headers[["Content-Type"]], "text/plain")
  expect_length(resp$headers, 1L)
})


test_that("header() and cookie() reject characters that could split a header", {

  expect_error(header(Location = "/a\r\nSet-Cookie: x=y"))
  expect_error(header("Bad Name" = "x"))
  expect_error(cookie(id = "a;b"))
  expect_error(cookie(id = "a b"))
  expect_error(cookie(id = "1", same_site = "Sometimes"))

  expect_identical(
    unclass(cookie(id = "1", path = "/", secure = TRUE, same_site = "None"))[["Set-Cookie"]],
    "id=1; Path=/; SameSite=None; Secure" )
})


test_that("is_int, is_bool and valid_string only accept single values", {

  expect_true(is_int(1L))
  expect_false(is_int(1))
  expect_false(is_int(NA_integer_))
  expect_false(is_int(1:2))

  expect_true(is_bool(FALSE))
  expect_false(is_bool(NA))
  expect_false(is_bool(c(TRUE, FALSE)))
  expect_false(is_bool("TRUE"))

  expect_true(valid_string("abc-1", ok = "-"))
  expect_false(valid_string("abc 1", ok = "-"))
  expect_false(valid_string(""))
  expect_false(valid_string(NULL))
  expect_true(valid_string(NULL, null_ok = TRUE))
  expect_false(valid_string("a\nb"))
  expect_false(valid_string("a;b", no = ";"))
})


test_that("numbers in a JSON response are not rounded", {

  # Found in the browser (step 7): p-values in a statistics table came out
  # as 0, because jsonlite keeps four decimal places unless told otherwise.
  body <- list(stats_table = data.frame(p_val = c(3.2e-07, 0.04567891), n = c(20L, 19L)), min = unbox(0.123456789))
  json <- response(body)$body

  expect_identical(fromJSON(json)$stats_table$p_val, c(3.2e-07, 0.04567891))
  expect_identical(fromJSON(json)$stats_table$n, c(20L, 19L))
  expect_identical(fromJSON(json)$min, 0.123456789)
})
