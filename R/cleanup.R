#______________________________________________________________________________
# Cleanup.
#
# The main process removes what nobody is using any more, when the server
# starts and then on a `later` timer:
#
#   1. Sessions that have signed out, or whose browser has not been heard
#      from for `session_ttl` seconds.
#   2. Drafts (unsaved working copies) that no session has open.
#   3. Guest users not seen for `guest_ttl` seconds who have no session,
#      and auth tokens that have expired.
#   4. Private projects that no user has in their tree any more.
#   5. `biom_files` rows that no project or draft refers to.
#   6. Files in `<data_dir>/files` that have no `biom_files` row and are
#      older than `session_ttl` (a job writes its files before the main
#      process records them, so new ones are left alone).
#   7. Temporary files: the figures, exports and uploads of a live session,
#      and those made for AI apps (`mcp/`), once they are older than
#      `session_ttl`; anything else in `temp_dir` once it is an hour old.
#
# Rules 1 to 5 run in one transaction and lean on the schema's foreign keys:
# deleting a user removes their permissions, and deleting a project removes
# its drafts. A saved project that still has a user is never touched.
#______________________________________________________________________________


# Seconds between cleanup runs.
cleanup_interval <- 600


#______________________________________________________________________________
#' Run every cleanup rule once.
#'
#' @param DB      The connection.
#' @param config  The server configuration: `data_dir`, `temp_dir`,
#'                `session_ttl` and `guest_ttl`.
#' @param now     The current time; tests pass other values.
#' @return A named list: how many of each kind of thing were removed.
#' @noRd
cleanup_run <- function (DB, config, now = Sys.time()) {

  session_cutoff <- now - config[['session_ttl']]
  guest_cutoff   <- now - config[['guest_ttl']]

  removed <- db_transaction(DB, list(
    sessions   = cleanup_sessions(DB, session_cutoff),
    drafts     = cleanup_drafts(DB),
    # Without accounts nobody new is a guest. Guests found there are from
    # before an upgrade, and what they own is the local user's own work.
    guests     = if (identical(config[['auth']], "none")) 0L else cleanup_guests(DB, guest_cutoff),
    tokens     = cleanup_tokens(DB, now),
    projects   = cleanup_projects(DB),
    biom_files = cleanup_biom_files(DB) ))

  removed[['stored_files']] <- cleanup_stored_files(DB, config, session_cutoff)
  removed[['temp_files']]   <- cleanup_temp(DB, config, session_cutoff, now - 3600)

  if (sum(unlist(removed)) > 0)
    do.call(log_event, c(list("info", "cleanup"), removed))

  return (removed)
}


#______________________________________________________________________________
#' Run cleanup now and then every `cleanup_interval` seconds.
#'
#' @param app  `list(db, config)`.
#' @return A function that stops the timer.
#' @noRd
cleanup_start <- function (app, interval = cleanup_interval) {

  stopped <- FALSE
  cancel  <- function () NULL

  tick <- function () {
    if (stopped) return (invisible(NULL))
    tryCatch(
      expr  = cleanup_run(app[['db']], app[['config']]),
      error = function (e) log_event("error", "cleanup_failed", message = log_truncate(conditionMessage(e), 2000L)) )
    cancel <<- later::later(tick, interval)
  }

  tick()

  function () {
    stopped <<- TRUE
    cancel()
    invisible(NULL)
  }
}


#' Delete the rows of a table that match a condition.
#'
#' @return The number of rows of that table deleted. (The count SQLite
#'         reports for a DELETE also includes rows removed from other
#'         tables by foreign keys.)
#' @noRd
delete_where <- function (DB, table, where, params = NULL) {

  stopifnot(isTRUE(grepl("^[a-z_]+$", table)))

  n <- db_query(DB, sprintf("SELECT COUNT(*) FROM %s WHERE %s", table, where), "Clean1", params)
  if (n > 0)
    db_query(DB, sprintf("DELETE FROM %s WHERE %s", table, where), "Clean2", params)

  as.integer(n)
}


#' A time in the form SQLite's CURRENT_TIMESTAMP uses.
#' @noRd
sql_time <- function (time) {
  format(time, "%Y-%m-%d %H:%M:%S", tz = "UTC")
}


#______________________________________________________________________________
#' Rule 1: sessions that signed out or went quiet.
#' @return The number of sessions deleted.
#' @noRd
cleanup_sessions <- function (DB, cutoff) {
  delete_where(DB, "sessions", "logout_utc IS NOT NULL OR heartbeat_utc < ?", list(sql_time(cutoff)))
}


#______________________________________________________________________________
#' Rule 2: drafts that no session has open.
#' @return The number of drafts deleted.
#' @noRd
cleanup_drafts <- function (DB) {
  delete_where(DB, "drafts", "draft_id NOT IN (SELECT draft_id FROM sessions WHERE draft_id IS NOT NULL)")
}


#______________________________________________________________________________
#' Rule 3: guests who have not been seen for a long time. Their permissions,
#' collections and auth tokens go with them.
#' @return The number of users deleted.
#' @noRd
cleanup_guests <- function (DB, cutoff) {
  where <- paste0(
    "is_guest = 1",
    " AND (seen_utc IS NULL OR seen_utc < ?)",
    " AND user_id NOT IN (SELECT user_id FROM sessions WHERE user_id IS NOT NULL)" )
  delete_where(DB, "users", where, list(sql_time(cutoff)))
}


#______________________________________________________________________________
#' Rule 3, second part: auth tokens that have expired. A browser that still
#' holds one starts again as a guest, or signs in again.
#' @return The number of tokens deleted.
#' @noRd
cleanup_tokens <- function (DB, now) {
  delete_where(DB, "auth_tokens", "expires_utc IS NULL OR expires_utc < ?", list(sql_time(now)))
}


#______________________________________________________________________________
#' Rule 4: private projects that are in nobody's tree: left behind by
#' "delete project", or by the removal of the only guest who had them.
#' @return The number of projects deleted.
#' @noRd
cleanup_projects <- function (DB) {
  delete_where(DB, "projects", "public_key IS NULL AND project_id NOT IN (SELECT project_id FROM permissions)")
}


#______________________________________________________________________________
#' Rule 5: rows for stored files that nothing refers to.
#' @return The number of rows deleted.
#' @noRd
cleanup_biom_files <- function (DB) {
  where <- paste0(
    "biom_file_id NOT IN (",
    "       SELECT orig_bf_id FROM projects",
    " UNION SELECT full_bf_id FROM projects",
    " UNION SELECT rare_bf_id FROM projects",
    " UNION SELECT full_bf_id FROM drafts",
    " UNION SELECT rare_bf_id FROM drafts )" )
  delete_where(DB, "biom_files", where)
}


#______________________________________________________________________________
#' Rule 6: files in the store that have no row and are not new.
#' @return The number of files deleted.
#' @noRd
cleanup_stored_files <- function (DB, config, cutoff) {

  files_dir <- file.path(config[['data_dir']], "files")

  known   <- dbGetQuery(DB, "SELECT file FROM biom_files")[[1]]
  present <- list.files(files_dir)
  unknown <- file.path(files_dir, setdiff(present, known))
  unknown <- unknown[!dir.exists(unknown)]
  old     <- unknown[file.mtime(unknown) < cutoff]

  sum(file.remove(old))
}


#______________________________________________________________________________
#' Rule 7: temporary files.
#'
#' Each live session has a directory named after its session key, and the
#' files made for tool calls are in `mcp` (`mcp_files()`). Files in those
#' are kept until `session_cutoff`; everything else in `temp_dir` is kept
#' until `other_cutoff`. Directories left empty are removed.
#'
#' Does nothing if `temp_dir` and `data_dir` overlap, so that a
#' misconfiguration cannot delete stored data.
#'
#' @return The number of files deleted.
#' @noRd
cleanup_temp <- function (DB, config, session_cutoff, other_cutoff) {

  temp_dir <- config[['temp_dir']]

  if (!dir.exists(temp_dir) || dirs_overlap(temp_dir, config[['data_dir']]))
    return (0L)

  live <- dbGetQuery(DB, "SELECT session_key FROM sessions WHERE session_key IS NOT NULL")[[1]]

  n <- 0L

  for (name in list.files(temp_dir, all.files = TRUE, no.. = TRUE)) {

    path   <- file.path(temp_dir, name)
    cutoff <- if (name %in% live || name == "mcp") session_cutoff else other_cutoff

    if (!dir.exists(path)) {
      if (file.mtime(path) < cutoff) n <- n + sum(file.remove(path))
      next
    }

    files <- list.files(path, recursive = TRUE, full.names = TRUE, all.files = TRUE)
    old   <- files[file.mtime(files) < cutoff]
    n     <- n + sum(file.remove(old))

    # Deepest first, so that a directory emptied here can go too. Removing
    # a directory that still has something in it fails, which is intended.
    dirs <- c(list.dirs(path, recursive = TRUE, full.names = TRUE), path)
    dirs <- unique(dirs[order(nchar(dirs), decreasing = TRUE)])
    for (dir in dirs)
      if (length(list.files(dir, all.files = TRUE, no.. = TRUE)) == 0)
        unlink(dir, recursive = TRUE)
  }

  return (n)
}


#______________________________________________________________________________
#' Is one directory the same as, or inside, the other?
#' @noRd
dirs_overlap <- function (a, b) {

  a <- paste0(sub("/+$", "", normalizePath(a, winslash = "/", mustWork = FALSE)), "/")
  b <- paste0(sub("/+$", "", normalizePath(b, winslash = "/", mustWork = FALSE)), "/")

  if (.Platform[['OS.type']] == "windows") {
    a <- tolower(a)
    b <- tolower(b)
  }

  startsWith(a, b) || startsWith(b, a)
}
