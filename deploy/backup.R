# Backups of an atima data directory, and putting one back.
#
# Run by the image's entry point (deploy/entrypoint.sh):
#
#   backup-loop      make a backup every night at ATIMA_BACKUP_HOUR (UTC)
#   backup           make one backup now
#   backups          list the backups there are
#   restore <name> [force]   put a backup back; stop the server first
#
# What a backup is. The database runs in WAL mode, so copying `sqlite.db`
# alone can give a broken file; SQLite's own backup API gives a consistent
# copy while the server runs. Each backup is one such copy,
# `<backup dir>/db/atima-<UTC time>.db`. The stored BIOM files are named by
# the SHA-256 of their contents and never change, so they are copied once
# into `<backup dir>/files/` and each database copy refers to them by name.
# The cache and the temporary directory are not backed up: both can be
# rebuilt.
#
# What is kept: the newest ATIMA_BACKUP_DAILY (7) backups, plus the newest
# backup of each of the last ATIMA_BACKUP_WEEKLY (4) ISO weeks. A stored
# file that the server has since deleted stays in the backup until no kept
# database copy refers to it any more.
#
# Also tidied here: before each schema upgrade the server saves
# `sqlite.db.v<N>.<date>.bak` in the data directory and never removes it;
# the newest ATIMA_BACKUP_UPGRADES (3) are kept.

data_dir   <- Sys.getenv("ATIMA_DATA_DIR",   "/var/lib/atima")
backup_dir <- Sys.getenv("ATIMA_BACKUP_DIR", "/backup")

setting <- function (name, default) {
  value <- suppressWarnings(as.integer(Sys.getenv(name, default)))
  if (is.na(value) || value < 0) stop(name, " must be a whole number, zero or more.", call. = FALSE)
  value
}

say <- function (event, ...) {
  cat(jsonlite::toJSON(auto_unbox = TRUE, c(
    list(time = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), event = event), list(...) )), "\n", sep = "")
}

backup_names <- function () {
  sort(list.files(file.path(backup_dir, "db"), pattern = "^atima-[0-9]{8}T[0-9]{6}Z\\.db$"), decreasing = TRUE)
}

backup_time <- function (names) {
  as.POSIXct(sub("^atima-(.*)\\.db$", "\\1", names), format = "%Y%m%dT%H%M%SZ", tz = "UTC")
}

# The stored files a database refers to.
referenced_files <- function (db_file) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_file, flags = RSQLite::SQLITE_RO)
  on.exit(DBI::dbDisconnect(con))
  if (!DBI::dbExistsTable(con, "biom_files")) return (character(0))
  DBI::dbGetQuery(con, "SELECT file FROM biom_files")[[1]]
}


backup <- function () {

  live <- file.path(data_dir, "sqlite.db")
  if (!file.exists(live)) stop("There is no database at ", live, call. = FALSE)

  dir.create(file.path(backup_dir, "db"),    recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(backup_dir, "files"), recursive = TRUE, showWarnings = FALSE)

  # Files first: a database copy must never name a file the backup lacks.
  files  <- list.files(file.path(data_dir, "files"))
  new    <- setdiff(files, list.files(file.path(backup_dir, "files")))
  copied <- 0L

  for (file in new) {
    from <- file.path(data_dir, "files", file)
    part <- file.path(backup_dir, "files", paste0(".", file, ".part"))
    # The server may delete an unreferenced file at any moment.
    if (file.exists(from) && file.copy(from, part, overwrite = TRUE)) {
      file.rename(part, file.path(backup_dir, "files", file))
      copied <- copied + 1L
    }
  }

  name <- format(Sys.time(), "atima-%Y%m%dT%H%M%SZ.db", tz = "UTC")
  part <- file.path(backup_dir, "db", paste0(".", name, ".part"))
  unlink(part)

  con <- DBI::dbConnect(RSQLite::SQLite(), live)
  tryCatch(
    finally = DBI::dbDisconnect(con),
    expr    = {
      DBI::dbExecute(con, "PRAGMA busy_timeout = 30000")
      RSQLite::sqliteCopyDatabase(con, part)
    })

  check <- DBI::dbConnect(RSQLite::SQLite(), part)
  ok    <- tryCatch(
    finally = DBI::dbDisconnect(check),
    expr    = {
      # A single file, with no -wal beside it, is what a backup should be.
      DBI::dbGetQuery(check, "PRAGMA journal_mode = DELETE")
      DBI::dbGetQuery(check, "PRAGMA integrity_check")[[1]]
    })

  if (!identical(ok, "ok")) {
    unlink(part)
    stop("The copy of the database failed its integrity check: ", paste(ok, collapse = "; "), call. = FALSE)
  }

  missing <- setdiff(referenced_files(part), list.files(file.path(backup_dir, "files")))
  file.rename(part, file.path(backup_dir, "db", name))

  say("backup", name = name, bytes = file.size(file.path(backup_dir, "db", name)),
      files_copied = copied, files_missing = length(missing))

  if (length(missing) > 0)
    say("backup_warning", message = "The database names stored files that are not in the data directory.", files = missing)

  prune()
  invisible(name)
}


prune <- function () {

  daily   <- setting("ATIMA_BACKUP_DAILY",    "7")
  weekly  <- setting("ATIMA_BACKUP_WEEKLY",   "4")
  upgrade <- setting("ATIMA_BACKUP_UPGRADES", "3")

  names <- backup_names()
  weeks <- format(backup_time(names), "%G-W%V")
  keep  <- union(
    utils::head(names, daily),
    names[!duplicated(weeks) & weeks %in% utils::head(unique(weeks), weekly)] )

  # Never remove the last backup there is, whatever the settings say.
  keep <- union(keep, utils::head(names, 1))
  drop <- setdiff(names, keep)
  unlink(file.path(backup_dir, "db", drop))

  # Stored files that neither a kept backup nor the live server refers to.
  wanted <- unique(c(
    list.files(file.path(data_dir, "files")),
    unlist(lapply(file.path(backup_dir, "db", keep), referenced_files)) ))
  stale <- setdiff(list.files(file.path(backup_dir, "files")), wanted)
  unlink(file.path(backup_dir, "files", stale))

  baks <- list.files(data_dir, pattern = "^sqlite\\.db\\.v[0-9]+\\..*\\.bak$", full.names = TRUE)
  baks <- baks[order(file.mtime(baks), decreasing = TRUE)]
  old  <- if (length(baks) > upgrade) baks[-seq_len(upgrade)] else character(0)
  unlink(old)

  if (length(drop) + length(stale) + length(old) > 0)
    say("backup_prune", backups = length(drop), files = length(stale), upgrade_copies = length(old))

  invisible(NULL)
}


restore <- function (name, force = FALSE) {

  if (is.na(name) || !name %in% backup_names())
    stop("No such backup. Run `backups` for the list.", call. = FALSE)

  from <- file.path(backup_dir, "db", name)
  live <- file.path(data_dir, "sqlite.db")

  # A running server keeps `sqlite.db-wal` and `sqlite.db-shm` beside the
  # database and removes them when it stops cleanly. (An idle server holds
  # no lock that could be tested for.) A server that was killed leaves them
  # behind as well: `restore <name> force` goes ahead regardless.
  if (any(file.exists(paste0(live, c("-wal", "-shm")))) && !force)
    stop(call. = FALSE, paste(
      "The database looks open: stop the atima server before restoring.",
      "If it is stopped, and was not shut down cleanly, add `force`." ))

  if (file.exists(live)) {
    aside <- paste0(live, format(Sys.time(), ".before-restore.%Y%m%dT%H%M%SZ", tz = "UTC"))
    file.rename(live, aside)
    say("restore_set_aside", file = basename(aside))
  }

  unlink(paste0(live, c("-wal", "-shm")))

  dir.create(file.path(data_dir, "files"), recursive = TRUE, showWarnings = FALSE)
  absent <- setdiff(referenced_files(from), list.files(file.path(data_dir, "files")))
  have   <- intersect(absent, list.files(file.path(backup_dir, "files")))
  file.copy(file.path(backup_dir, "files", have), file.path(data_dir, "files", have))

  if (!file.copy(from, live)) stop("Could not copy the backup into the data directory.", call. = FALSE)

  # What the server computed from the old state is of no use to the new.
  unlink(file.path(data_dir, "cache"), recursive = TRUE)

  say("restore", name = name, files_restored = length(have), files_missing = length(setdiff(absent, have)))
  invisible(NULL)
}


# Sleep until the next ATIMA_BACKUP_HOUR (UTC), back up, and again.
backup_loop <- function () {

  hour <- setting("ATIMA_BACKUP_HOUR", "8")
  if (hour > 23) stop("ATIMA_BACKUP_HOUR must be 0 to 23.", call. = FALSE)

  say("backup_loop", hour_utc = hour, backup_dir = backup_dir)

  repeat {
    now  <- as.POSIXlt(Sys.time(), tz = "UTC")
    wait <- ((hour - now$hour) %% 24) * 3600 - now$min * 60 - now$sec
    if (wait <= 0) wait <- wait + 86400
    Sys.sleep(wait)
    tryCatch(backup(), error = function (e) say("backup_failed", message = conditionMessage(e)))
  }
}


args <- commandArgs(trailingOnly = TRUE)

switch(
  EXPR = if (length(args) > 0) args[[1]] else "",
  "backup"      = backup(),
  "backup-loop" = backup_loop(),
  "restore"     = restore(args[2], force = identical(args[3], "force")),
  "backups"     = {
    names <- backup_names()
    if (length(names) == 0) cat("No backups in ", backup_dir, "\n", sep = "")
    for (name in names)
      cat(sprintf("%s  %8.1f MB\n", name, file.size(file.path(backup_dir, "db", name)) / 1e6))
  },
  stop("Usage: backup | backup-loop | backups | restore <name> [force]", call. = FALSE) )
