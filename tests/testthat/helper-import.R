# Uploads of every kind, for test-import.R.

# A QIIME 2 artifact kept in git; see fixtures/uploads/make.R.
upload_fixture <- function (name) testthat::test_path("fixtures", "uploads", name)


# The dataset the artifacts were made from: eight samples, thirty OTUs, a
# tree, four metadata fields.
upload_biom <- function () {
  biom <- rbiom::hmp50[1:8]$clone()
  keep <- names(sort(rowSums(as.matrix(biom$counts)), decreasing = TRUE))[1:30]
  biom$counts <- biom$counts[keep, ]
  biom
}


# What a worker needs to import files, in a temporary directory, and
# shorthands for the jobs. A file is handed over as the server keeps an
# upload: under a random name with no extension.
local_import <- function (env = parent.frame()) {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  dir <- withr::local_tempdir(pattern = "atima_import_", .local_envir = env)
  for (sub in c("files", "cache", "temp")) dir.create(file.path(dir, sub))

  ctx <- list(files_dir = file.path(dir, "files"), cache_dir = file.path(dir, "cache"), cache_size = 1e8, cpus = 1L)

  upload <- function (file) {
    infile <- tempfile(pattern = "upload_", tmpdir = file.path(dir, "temp"))
    stopifnot(file.copy(file, infile))
    infile
  }

  # A file made on the spot from lines of text.
  written <- function (lines) {
    file <- tempfile(tmpdir = file.path(dir, "temp"))
    writeLines(lines, file)
    file
  }

  stored <- function (entry) file.path(ctx$files_dir, entry$file)

  list(
    ctx     = ctx,
    dir     = dir,
    upload  = upload,
    written = written,
    stored  = stored,
    import  = function (file, name = basename(file), ...) work_import(ctx, upload(file), filename = name, ...),
    replace = function (project, component, file, name = basename(file)) {
      work_component(ctx, stored(project$full), stored(project$rare), component, upload(file), name)
    })
}


# The error a file is refused with: a 400 written for the user.
refusal <- function (code) {
  e <- tryCatch({ code; NULL }, error = function (e) e)
  expect_s3_class(e, "atima_http_error")
  expect_identical(e$status, 400L)
  e
}


# Nothing in a text that was made for the user says where the server keeps
# its files.
expect_no_server_path <- function (text, im = NULL) {
  text <- paste(text, collapse = "\n")
  dirs <- c(tempdir(), im$dir, dirname(tempdir()))
  dirs <- unique(c(dirs, normalizePath(dirs, winslash = "/"), normalizePath(dirs, winslash = "\\")))
  for (dir in dirs) expect_false(grepl(tolower(dir), tolower(text), fixed = TRUE), info = text)
  expect_no_match(text, "upload_[0-9a-f]{6}")
  expect_no_match(text, "Rtmp|atima_import_|atima_test_|atima_temp_")
  expect_no_match(text, "[A-Za-z]:[\\\\/]")
}
