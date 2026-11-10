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
