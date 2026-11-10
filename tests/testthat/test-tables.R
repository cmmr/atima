test_that("dt_page pages, searches and sorts", {

  df <- data.frame(
    sample = sprintf("S%02d", 1:25),
    site   = rep(c("Gut", "Skin", "Oral", "Nose", "Gut"), 5),
    stringsAsFactors = FALSE )

  # Defaults: the first ten rows, in order.
  page <- dt_page(df)
  expect_identical(page$recordsTotal, jsonlite::unbox(25L))
  expect_identical(page$recordsFiltered, jsonlite::unbox(25L))
  expect_identical(page$data[, "sample"], sprintf("S%02d", 1:10))

  # Regression: a page used to come back one row too long.
  expect_identical(dt_page(df, start = 10L, length = 5L)$data[, "sample"], sprintf("S%02d", 11:15))
  expect_identical(dt_page(df, start = 20L, length = 10L)$data[, "sample"], sprintf("S%02d", 21:25))
  expect_identical(nrow(dt_page(df, start = 100L)$data), 0L)

  # Search is case-insensitive and matches any column.
  page <- dt_page(df, length = 100L, search = list(value = "SKIN", regex = FALSE))
  expect_identical(page$recordsFiltered, jsonlite::unbox(5L))
  expect_true(all(page$data[, "site"] == "Skin"))

  # DataTables sends `order` as an array of objects, which arrives as a
  # data frame; a single object arrives as a list.
  page <- dt_page(df, length = 3L, order = data.frame(column = 0L, dir = "desc"))
  expect_identical(page$data[, "sample"], c("S25", "S24", "S23"))
  page <- dt_page(df, length = 3L, order = list(column = 0L, dir = "desc"))
  expect_identical(page$data[, "sample"], c("S25", "S24", "S23"))

  expect_error(dt_page(df, order = list(column = 7L, dir = "asc")), class = "atima_http_error")
})
