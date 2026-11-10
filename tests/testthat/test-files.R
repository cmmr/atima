test_that("read_file_raw returns the whole file", {

  file <- withr::local_tempfile()
  writeBin(as.raw(1:200), file)

  expect_identical(read_file_raw(file), as.raw(1:200))
  expect_identical(read_file_raw(file.path(tempdir(), "no-such-file")), raw(0))
})


test_that("store_file keeps one copy of identical files", {

  REQ <- local_test_req()

  a <- withr::local_tempfile(); writeLines("sample,count\nA,1", a)
  b <- withr::local_tempfile(); writeLines("sample,count\nA,1", b)
  c <- withr::local_tempfile(); writeLines("sample,count\nA,2", c)

  id_a <- store_file(REQ, a)
  id_b <- store_file(REQ, b)
  id_c <- store_file(REQ, c)

  expect_identical(id_b, id_a)
  expect_false(identical(id_c, id_a))

  stored <- db_query(REQ$DB, "SELECT file FROM biom_files WHERE biom_file_id = ?", "Test1", list(id_c))
  expect_identical(
    read_file_raw(file.path(REQ$CONFIG$data_dir, "files", stored)),
    read_file_raw(c) )
})


test_that("store_file compares whole files when hashes collide", {

  # Regression: only the first byte of each file used to be compared, so two
  # different files with the same hash and first byte were treated as one.
  REQ <- local_test_req()
  local_mocked_bindings(hash_file = function (...) "same-hash")

  a <- withr::local_tempfile(); writeLines("same first byte, version 1", a)
  b <- withr::local_tempfile(); writeLines("same first byte, version 2", b)

  id_a <- store_file(REQ, a)
  id_b <- store_file(REQ, b)

  expect_false(identical(id_a, id_b))
  expect_identical(store_file(REQ, b), id_b)
})


test_that("plot_filename never hands out the same name twice", {

  dir   <- withr::local_tempdir()
  files <- replicate(50, plot_filename(dir, "png"))

  expect_identical(anyDuplicated(files), 0L)
  expect_true(all(grepl("^plot_[A-Za-z0-9]{10}\\.png$", files)))
  expect_true(all(file.exists(file.path(dir, files))))
})


test_that("api_export accepts digits 2-9 in path terms", {

  # Regression: the term check used [0-1] where [0-9] was meant, so exports
  # such as "taxa/Rank2" were refused.
  temp <- withr::local_tempdir()
  local_mocked_bindings(
    db_query    = function (...) list(orig_bf_id = 1L, full_bf_id = 2L, rare_bf_id = 3L),
    get_biom    = function (...) list(),
    taxa_matrix = function (biom, rank) matrix(1:4, 2, dimnames = list(c("a", "b"), c("s1", "s2"))) )

  req <- function (path)
    list(PATH = path, SESSION = list(project_id = 1L, client_temp = "/tmp/key", server_temp = temp))

  resp <- api_export(req("/api/export/taxa/Rank2/rare"))
  expect_identical(resp, list(download_url = jsonlite::unbox("/tmp/key/3/Rank2_rare_3.csv")))
  expect_true(file.exists(file.path(temp, "3", "Rank2_rare_3.csv")))

  expect_error(api_export(req("/api/export/taxa/..%2F..%2Fetc/rare")), "Invalid export term")
  expect_error(api_export(req("/api/export/taxa/a_b/rare")),           "Invalid export term")
})
