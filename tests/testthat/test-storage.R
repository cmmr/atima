# The content-addressed file store and atomic writes.


test_that("read_file_raw returns the whole file", {

  file <- withr::local_tempfile()
  writeBin(as.raw(1:200), file)

  expect_identical(read_file_raw(file), as.raw(1:200))
  expect_identical(read_file_raw(file.path(tempdir(), "no-such-file")), raw(0))
})


test_that("atomic_write shows the whole file or nothing", {

  dir  <- withr::local_tempdir()
  path <- file.path(dir, "result.txt")

  # While the content is being written, nothing exists under the final name,
  # and the temporary file is in the same directory (so the rename is atomic).
  atomic_write(path, function (tmp) {
    expect_false(file.exists(path))
    expect_identical(dirname(tmp), dirname(path))
    writeLines("first half", tmp)
    expect_false(file.exists(path))
    writeLines(c("first half", "second half"), tmp)
  })

  expect_identical(readLines(path), c("first half", "second half"))
  expect_identical(list.files(dir), "result.txt")

  # A failed write leaves the previous content and no temporary file.
  expect_error(atomic_write(path, function (tmp) { writeLines("partial", tmp); stop("disk full") }), "disk full")
  expect_identical(readLines(path), c("first half", "second half"))
  expect_identical(list.files(dir), "result.txt")

  # A writer that writes nothing is an error, not an empty file.
  expect_error(atomic_write(file.path(dir, "other.txt"), function (tmp) NULL), "Nothing was written")
  expect_identical(list.files(dir), "result.txt")

  # An existing file is replaced in one step.
  atomic_write(path, function (tmp) writeLines("replaced", tmp))
  expect_identical(readLines(path), "replaced")
})


test_that("store_file names a file after its content and keeps one copy", {

  REQ       <- local_test_req()
  files_dir <- file.path(REQ$CONFIG$data_dir, "files")

  a <- withr::local_tempfile(); writeLines("sample,count\nA,1", a)
  b <- withr::local_tempfile(); writeLines("sample,count\nA,1", b)
  c <- withr::local_tempfile(); writeLines("sample,count\nA,2", c)

  entry_a <- store_file(files_dir, a)
  entry_b <- store_file(files_dir, b)
  entry_c <- store_file(files_dir, c)

  expect_identical(entry_a$hash, paste(as.character(openssl::sha256(file(a)))))
  expect_identical(entry_a$file, paste0(entry_a$hash, ".biom"))
  expect_identical(entry_b, entry_a)
  expect_false(identical(entry_c$hash, entry_a$hash))

  expect_setequal(list.files(files_dir), c(entry_a$file, entry_c$file))
  expect_identical(read_file_raw(file.path(files_dir, entry_c$file)), read_file_raw(c))

  # Storing content that is already there refreshes its age, so that cleanup
  # does not mistake it for an abandoned file.
  stored <- file.path(files_dir, entry_a$file)
  Sys.setFileTime(stored, Sys.time() - 86400 * 3)
  store_file(files_dir, a)
  expect_gt(as.numeric(file.mtime(stored)), as.numeric(Sys.time()) - 60)
})


test_that("register_biom_file gives identical content one row", {

  REQ       <- local_test_req()
  files_dir <- file.path(REQ$CONFIG$data_dir, "files")

  a <- withr::local_tempfile(); writeLines("one", a)
  b <- withr::local_tempfile(); writeLines("two", b)

  id_a <- register_biom_file(REQ$DB, store_file(files_dir, a))
  id_b <- register_biom_file(REQ$DB, store_file(files_dir, b))

  expect_false(identical(id_a, id_b))
  expect_identical(register_biom_file(REQ$DB, store_file(files_dir, a)), id_a)
  expect_identical(db_query(REQ$DB, "SELECT COUNT(*) FROM biom_files", "T1"), 2L)

  REQ$SESSION <- list()
  expect_identical(read_file_raw(biom_path(REQ, id_b)), read_file_raw(b))

  # Only a real store entry is accepted.
  expect_error(register_biom_file(REQ$DB, list(file = "../sqlite.db", hash = "abc")))
  expect_error(register_biom_file(REQ$DB, list(file = "x.biom", hash = strrep("a", 64))))
})


test_that("files stored by atima 5.0.x are adopted into the new layout", {

  REQ       <- local_test_req()
  DB        <- REQ$DB
  files_dir <- file.path(REQ$CONFIG$data_dir, "files")

  # Two old-style rows with the same content, one with different content,
  # and one whose file is missing.
  writeLines("same content",  file.path(files_dir, "aaaaaaaaaa.biom"))
  writeLines("same content",  file.path(files_dir, "bbbbbbbbbb.biom"))
  writeLines("other content", file.path(files_dir, "cccccccccc.biom"))

  id <- function (file, hash) db_insert(DB, "biom_files", "T1", file = file, hash = hash)
  a  <- id("aaaaaaaaaa.biom", "oldhash-a")
  b  <- id("bbbbbbbbbb.biom", "oldhash-b")
  c  <- id("cccccccccc.biom", "oldhash-c")
  d  <- id("dddddddddd.biom", "oldhash-d")

  project <- db_insert(
    DB, "projects", "T2", title = "Old project",
    orig_bf_id = a, full_bf_id = b, rare_bf_id = c, access_key = "oldproject" )

  expect_identical(storage_adopt_legacy(DB, files_dir), 3L)

  rows <- db_query(DB, "SELECT * FROM biom_files ORDER BY biom_file_id", "T3")
  sha  <- function (text) { f <- tempfile(); on.exit(unlink(f)); writeLines(text, f); file_sha256(f) }

  # a keeps its id under the new name; b is folded into a; c is renamed;
  # d, with no file, is left alone.
  expect_identical(rows$biom_file_id, c(a, c, d))
  expect_identical(rows$hash, c(sha("same content"), sha("other content"), "oldhash-d"))
  expect_identical(rows$file[1:2], paste0(rows$hash[1:2], ".biom"))
  expect_true(all(file.exists(file.path(files_dir, rows$file[1:2]))))

  expect_identical(
    db_query(DB, "SELECT orig_bf_id, full_bf_id, rare_bf_id FROM projects WHERE project_id = ?", "T4", list(project)),
    list(orig_bf_id = a, full_bf_id = a, rare_bf_id = c) )

  # Running it again changes nothing.
  expect_identical(storage_adopt_legacy(DB, files_dir), 0L)
})
