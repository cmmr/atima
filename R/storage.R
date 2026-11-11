#______________________________________________________________________________
# Stored BIOM files.
#
# Every BIOM file atima keeps lives in `<data_dir>/files` under the SHA-256 of
# its contents: `<sha256>.biom`. Identical content is therefore stored once,
# and a file never changes after it has been written. Worker processes write
# into this directory; only the main process records a file in the
# `biom_files` table, when the job that made it finishes. A file that no row
# refers to is removed by the cleanup timer once it is a day old.
#
# Nothing is ever written in place. A file is written under a temporary name
# in the same directory and then renamed, so a reader sees either the whole
# file or no file.
#______________________________________________________________________________


#______________________________________________________________________________
#' Write a file so that it appears all at once.
#'
#' @param path   Where the file should end up.
#' @param write  A function that takes a temporary path and writes the
#'               content there.
#' @return `path`, invisibly.
#' @noRd
atomic_write <- function (path, write) {

  tmp <- sprintf("%s.%i.%s.tmp", path, Sys.getpid(), random_string(8))
  on.exit(unlink(tmp), add = TRUE)

  write(tmp)

  if (!file.exists(tmp))
    stop("Nothing was written for '", basename(path), "'.")

  # Windows refuses to replace a file while another process has it open, so
  # give a reader a moment to finish.
  for (attempt in 1:20) {
    if (suppressWarnings(file.rename(tmp, path))) return (invisible(path))
    Sys.sleep(0.05)
  }

  stop("Unable to move a finished file into place: '", basename(path), "'.")
}


#______________________________________________________________________________
#' The SHA-256 of a file's contents, as 64 hex characters.
#' @noRd
file_sha256 <- function (file) {
  con <- file(file, open = "rb")
  on.exit(close(con), add = TRUE)
  paste(as.character(sha256(con)), collapse = "")
}


#______________________________________________________________________________
#' Copy a file into the store under the hash of its contents.
#'
#' Safe to call from any process, and from several at once: the name depends
#' only on the content, and the copy is atomic.
#'
#' @param files_dir  `<data_dir>/files`.
#' @param file       The file to store.
#' @return `list(file, hash)`: the name inside `files_dir` and the SHA-256.
#'         Pass it to `register_biom_file()` in the main process.
#' @noRd
store_file <- function (files_dir, file) {

  hash <- file_sha256(file)
  name <- paste0(hash, ".biom")
  dest <- file.path(files_dir, name)

  if (file.exists(dest)) {
    # Already stored. Refresh its age so that cleanup does not take it for
    # an abandoned file before the main process has recorded it.
    Sys.setFileTime(dest, Sys.time())
  } else {
    atomic_write(dest, function (tmp) file.copy(file, tmp))
  }

  list(file = name, hash = hash)
}


#______________________________________________________________________________
#' Record a stored file in the database, or find the row it already has.
#'
#' Main process only.
#'
#' @param DB     The connection.
#' @param entry  `list(file, hash)` from `store_file()`.
#' @return A `biom_file_id`.
#' @noRd
register_biom_file <- function (DB, entry) {

  stopifnot(
    is.list(entry),
    isTRUE(grepl("^[0-9a-f]{64}$", entry[['hash']])),
    identical(entry[['file']], paste0(entry[['hash']], ".biom")) )

  sql <- "SELECT biom_file_id FROM biom_files WHERE hash = ? ORDER BY biom_file_id LIMIT 1"
  id  <- db_query(DB, sql, "RBFile1", list(entry[['hash']]))
  if (!is.null(id)) return (id)

  sql <- "INSERT INTO biom_files (file, hash) VALUES (?, ?)"
  db_query(DB, sql, "RBFile2", list(entry[['file']], entry[['hash']]))
}


#______________________________________________________________________________
#' The path of a stored BIOM file. Main process only.
#' @noRd
biom_path <- function (REQ, biom_file_id) {
  sql  <- "SELECT file FROM biom_files WHERE biom_file_id = ?"
  file <- db_query(REQ[['DB']], sql, "BPath1", list(biom_file_id), req1 = TRUE)
  file.path(REQ[['CONFIG']][['data_dir']], "files", file)
}


#______________________________________________________________________________
#' Bring files stored by atima 5.0.x into the content-addressed layout.
#'
#' Older versions gave stored files random names and recorded a
#' non-cryptographic hash. Each such row is pointed at a copy named after its
#' SHA-256; if that content is already recorded, the projects and drafts that
#' used the old row are moved to the existing one. The old files are left for
#' the cleanup timer, which removes files that no row refers to.
#'
#' @return The number of rows changed, invisibly.
#' @noRd
storage_adopt_legacy <- function (DB, files_dir) {

  rows <- dbGetQuery(DB, "SELECT biom_file_id, file, hash FROM biom_files")
  rows <- rows[!grepl("^[0-9a-f]{64}$", rows[['hash']]),, drop = FALSE]

  changed <- 0L

  for (i in seq_len(nrow(rows))) {

    old_id <- rows[i, 'biom_file_id']
    old    <- file.path(files_dir, rows[i, 'file'])
    if (!nzchar(rows[i, 'file']) || !file.exists(old)) next

    entry <- store_file(files_dir, old)

    db_transaction(DB, {

      sql    <- "SELECT biom_file_id FROM biom_files WHERE hash = ? ORDER BY biom_file_id LIMIT 1"
      new_id <- db_query(DB, sql, "SALeg1", list(entry[['hash']]))

      if (is.null(new_id)) {
        sql <- "UPDATE biom_files SET file = ?, hash = ? WHERE biom_file_id = ?"
        db_query(DB, sql, "SALeg2", list(entry[['file']], entry[['hash']], old_id))

      } else {
        for (ref in c("projects.orig_bf_id", "projects.full_bf_id", "projects.rare_bf_id", "drafts.full_bf_id", "drafts.rare_bf_id")) {
          ref <- strsplit(ref, ".", fixed = TRUE)[[1]]
          sql <- sprintf("UPDATE %s SET %s = ? WHERE %s = ?", ref[[1]], ref[[2]], ref[[2]])
          db_query(DB, sql, "SALeg3", list(new_id, old_id))
        }
        db_query(DB, "DELETE FROM biom_files WHERE biom_file_id = ?", "SALeg4", list(old_id))
      }
    })

    changed <- changed + 1L
  }

  if (changed > 0)
    log_event("info", "storage_adopt_legacy", files = changed)

  invisible(changed)
}
