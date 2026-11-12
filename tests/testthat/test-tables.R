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


test_that("dt_page sorts a column of numbers as numbers", {

  # Found in the browser (step 7): every column was sorted as text, which
  # puts 100 before 9.
  df <- data.frame(
    sample = c("a", "b", "c", "d", "e"),
    age    = c(9, 100, 25, NA, 9),
    site   = factor(c("Gut", "Skin", "Gut", "Oral", "Skin")),
    stringsAsFactors = FALSE )

  page <- dt_page(df, order = list(column = 1L, dir = "asc"))
  expect_identical(page$data[, "sample"], c("a", "e", "c", "b", "d"))
  expect_identical(page$data[, "age"], c("9", "9", "25", "100", ""))

  page <- dt_page(df, order = list(column = 1L, dir = "desc"))
  expect_identical(page$data[, "sample"], c("b", "c", "a", "e", "d"))

  # Two sort columns: the first decides, the second breaks its ties.
  page <- dt_page(df, order = data.frame(column = c(2L, 0L), dir = c("asc", "desc")))
  expect_identical(page$data[, "sample"], c("c", "a", "d", "e", "b"))

  # Searching, then sorting, then paging.
  page <- dt_page(df, start = 1L, length = 1L, search = list(value = "skin"), order = list(column = 1L, dir = "asc"))
  expect_identical(page$recordsFiltered, jsonlite::unbox(2L))
  expect_identical(unname(page$data[, "sample"]), "b")
})
