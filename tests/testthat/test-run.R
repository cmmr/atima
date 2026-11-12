test_that("run() listens on loopback by default", {
  expect_identical(formals(run)$host, "127.0.0.1")
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
