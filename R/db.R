#______________________________________________________________________________
# The SQLite database.
#
# The main R process opens one connection in `run()` and keeps it until the
# server stops. Nothing else opens the database; worker processes never do. The schema is created and
# upgraded by the numbered scripts in `inst/sql/`; the number of the last
# script applied is kept in `PRAGMA user_version`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Open the database in `data_dir`, creating or upgrading it as needed.
#'
#' @param data_dir  The directory that holds (or will hold) `sqlite.db`.
#' @return A DBI connection with write-ahead logging, a busy timeout and
#'         foreign key enforcement switched on.
#' @noRd
db_open <- function (data_dir) {

  db_file <- file.path(data_dir, "sqlite.db")

  DB <- tryCatch(
    expr  = dbConnect(drv = SQLite(), dbname = db_file),
    error = function (e) stop("Unable to open the database at ", db_file, ": ", conditionMessage(e), call. = FALSE) )

  tryCatch(
    expr = {
      dbGetQuery(DB, "PRAGMA journal_mode = WAL")
      dbExecute(DB,  "PRAGMA synchronous = NORMAL")
      dbGetQuery(DB, "PRAGMA busy_timeout = 5000")
      dbExecute(DB,  "PRAGMA foreign_keys = ON")
      db_migrate(DB, data_dir)
    },
    error = function (e) {
      db_close(DB)
      stop(e)
    })

  return (DB)
}


#______________________________________________________________________________
#' Checkpoint and close the database connection.
#' @noRd
db_close <- function (DB) {
  stopifnot(is(DB, "SQLiteConnection"))
  # Fold the write-ahead log back into the database file, so that the file
  # is complete on its own once the server has stopped.
  try(silent = TRUE, dbGetQuery(DB, "PRAGMA wal_checkpoint(TRUNCATE)"))
  try(silent = TRUE, dbDisconnect(DB))
  invisible(NULL)
}


#______________________________________________________________________________
#' The migration scripts shipped with the package, in the order they run.
#'
#' @param dir  The directory to look in.
#' @return A data frame with columns `version` (integer) and `file` (path).
#' @noRd
db_migrations <- function (dir = system.file("sql", package = "atima")) {

  files    <- list.files(dir, pattern = "^[0-9]{3}_[a-z0-9_]+\\.sql$", full.names = TRUE)
  versions <- as.integer(substr(basename(files), 1, 3))
  ord      <- order(versions)
  files    <- files[ord]
  versions <- versions[ord]

  if (length(files) == 0)
    stop("No migration scripts found in ", dir, call. = FALSE)

  if (!identical(versions, seq_along(versions)))
    stop("Migration scripts must be numbered 001, 002, ... with no gaps.", call. = FALSE)

  data.frame(version = versions, file = files, stringsAsFactors = FALSE)
}


#______________________________________________________________________________
#' Bring the database schema up to the latest version.
#'
#' A database made by atima 5.0.x has tables but no version number. It is
#' treated as version 1, which is exactly the schema that
#' `001_baseline.sql` creates, and upgraded from there. A database that
#' already holds data is copied to a backup file before it is changed.
#'
#' @param DB        The connection.
#' @param data_dir  Where to put the backup.
#' @param migrations  The scripts to apply, from `db_migrations()`.
#' @return The schema version, invisibly.
#' @noRd
db_migrate <- function (DB, data_dir, migrations = db_migrations()) {

  latest  <- max(migrations[['version']])
  version <- db_version(DB)
  tables  <- dbListTables(DB)

  if (version > latest)
    stop(call. = FALSE, sprintf(
      "This database has schema version %i, but this version of atima only knows up to %i. Install a newer atima.",
      version, latest ))

  if (version == latest)
    return (invisible(version))

  # Tables, but no version: created by atima 5.0.x.
  from_5.0 <- version == 0L && "users" %in% tables

  if (length(tables) > 0) {
    backup <- db_backup(DB, data_dir, version)
    log_event("info", "db_backup", file = backup, schema_version = version)
  }

  if (from_5.0) {
    dbExecute(DB, "PRAGMA user_version = 1")
    version <- 1L
  }

  pending <- migrations[migrations[['version']] > version,, drop = FALSE]

  for (i in seq_len(nrow(pending))) {
    db_run_migration(DB, pending[i, 'file'], pending[i, 'version'])
    log_event("info", "db_migration", schema_version = pending[i, 'version'], script = basename(pending[i, 'file']))
  }

  return (invisible(latest))
}


#______________________________________________________________________________
#' The schema version stored in the database file.
#' @noRd
db_version <- function (DB) {
  as.integer(dbGetQuery(DB, "PRAGMA user_version")[[1]])
}


#______________________________________________________________________________
#' Copy the whole database to a new file next to it.
#' @return The path of the backup file.
#' @noRd
db_backup <- function (DB, data_dir, version) {

  stamp  <- format(Sys.time(), "%Y%m%d-%H%M%S", tz = "UTC")
  backup <- file.path(data_dir, sprintf("sqlite.db.v%i.%s.bak", version, stamp))

  for (i in 1:100) {
    if (!file.exists(backup)) break
    backup <- file.path(data_dir, sprintf("sqlite.db.v%i.%s-%i.bak", version, stamp, i))
  }

  dbExecute(DB, paste0("VACUUM INTO '", gsub("'", "''", backup, fixed = TRUE), "'"))

  return (backup)
}


#______________________________________________________________________________
#' Run one migration script and record its version, all or nothing.
#'
#' Foreign keys are not enforced while the script runs, because rebuilding a
#' table means dropping it. Every key is checked before the commit.
#' @noRd
db_run_migration <- function (DB, file, version) {

  statements <- sql_statements(file)

  dbExecute(DB, "PRAGMA foreign_keys = OFF")
  on.exit(dbExecute(DB, "PRAGMA foreign_keys = ON"), add = TRUE)

  dbExecute(DB, "BEGIN IMMEDIATE")

  tryCatch(
    expr = {

      for (sql in statements)
        dbExecute(DB, sql)

      broken <- dbGetQuery(DB, "PRAGMA foreign_key_check")
      if (nrow(broken) > 0)
        stop(sprintf(
          "%i row(s) break a foreign key, first in table '%s'.",
          nrow(broken), broken[1, 'table'] ))

      dbExecute(DB, sprintf("PRAGMA user_version = %i", as.integer(version)))
      dbExecute(DB, "COMMIT")
    },
    error = function (e) {
      try(silent = TRUE, dbExecute(DB, "ROLLBACK"))
      stop(call. = FALSE, sprintf(
        "Database migration %s failed and was rolled back: %s",
        basename(file), conditionMessage(e) ))
    })

  invisible(NULL)
}


#______________________________________________________________________________
#' Split an SQL script into its statements.
#'
#' Lines that start with `--` are comments. A statement ends at a semicolon
#' that is the last thing on its line, so the scripts must not put two
#' statements on one line.
#' @return A character vector, one statement each, without the semicolons.
#' @noRd
sql_statements <- function (file) {

  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  lines <- lines[!grepl("^\\s*--", lines)]
  lines <- sub("\\s+$", "", lines)

  ends       <- endsWith(lines, ";")
  group      <- cumsum(c(0L, head(ends, -1L)))
  statements <- vapply(split(lines, group), paste, character(1), collapse = "\n")
  statements <- trimws(sub(";$", "", statements))

  unname(statements[nzchar(statements)])
}


#______________________________________________________________________________
#' Run code inside a database transaction.
#'
#' If `code` finishes, its changes are committed. If it stops with an error,
#' everything it changed is rolled back and the error continues upward.
#' Calls can be nested: an inner transaction that fails undoes only its own
#' changes, and nothing is permanent until the outermost one finishes.
#'
#' @param DB    The connection.
#' @param code  The code to run.
#' @return The value of `code`.
#' @noRd
db_transaction <- function (DB, code) {

  stopifnot(is(DB, "SQLiteConnection"))

  # A savepoint outside a transaction starts one, so one mechanism covers
  # both the outermost and the nested case.
  dbExecute(DB, "SAVEPOINT atima_tx")

  ok <- FALSE
  on.exit(add = TRUE, expr = {
    if (!ok) try(silent = TRUE, dbExecute(DB, "ROLLBACK TO atima_tx"))
    try(silent = TRUE, dbExecute(DB, "RELEASE atima_tx"))
  })

  value <- withVisible(force(code))
  ok    <- TRUE

  if (value[['visible']]) value[['value']] else invisible(value[['value']])
}


#______________________________________________________________________________
#' Run one SQL statement.
#'
#' @param DB  The connection.
#' @param sql  A single SELECT, INSERT, UPDATE or DELETE statement.
#' @param err_code  A short code that identifies the call site in the log.
#' @param params  A list of values for the statement's `?` placeholders.
#' @param simplify  Return single values or named lists instead of data frames
#'        whenever possible.
#' @param req1  Stop unless a SELECT matches exactly one row.
#'
#' @return For a SELECT, a data frame, simplified if `simplify = TRUE`: `NULL`
#'         for no rows, a vector for one column, a list for one row. For an
#'         INSERT, the new rowid. Otherwise the number of rows changed.
#'
#'         A failure raises an `atima_db_error`. Its message names only
#'         `err_code`; the SQL and parameters are fields of the condition,
#'         for the log.
#' @noRd
db_query <- function (DB, sql, err_code, params = NULL, simplify = TRUE, req1 = FALSE) {

  stopifnot(is(DB, "SQLiteConnection"))
  stopifnot(is_scalar_character(sql))
  stopifnot(is_scalar_character(err_code))

  sql  <- trimws(gsub("[\n\r\t\ ]+", " ", sql))
  verb <- toupper(strsplit(substr(sql, 1, 10), ' ', fixed = TRUE)[[1]][[1]])

  # A time is stored as text, the way SQLite's CURRENT_TIMESTAMP writes it.
  # Bound as it is, it would be stored as a number of seconds, which the
  # conversion of `*_utc` columns below cannot read back.
  if (!is.null(params))
    params <- lapply(unname(as.list(params)), function (p) if (inherits(p, "POSIXct")) sql_time(p) else p)

  result <- tryCatch(

    error = function (e) stop_db(err_code, e, sql, params),

    expr = {

      if (!is_one_of(verb, c("SELECT", "INSERT", "UPDATE", "DELETE")))
        stop("Invalid SQL verb: '", verb, "'.")

      result <- do.call(
        what = if (verb == "SELECT") dbGetQuery else dbExecute,
        args = list(conn = DB, statement = sql, params = params) )

      # For INSERT statements, the result is the new rowid.
      if (verb == "INSERT")
        result <- dbGetQuery(DB, "SELECT LAST_INSERT_ROWID()")[1,1]

      if (verb == "SELECT" && isTRUE(req1) && nrow(result) != 1)
        stop("Expected exactly one row, found ", nrow(result), ".")

      result
    })

  if (verb != "SELECT") return (result)


  #________________________________________________________
  # Use column names to convert to boolean and POSIXct.
  #________________________________________________________
  for (k in colnames(result)) {
    if        (startsWith(k, "is_"))  { result[[k]] <- as.logical(result[[k]])
    } else if (startsWith(k, "has_")) { result[[k]] <- as.logical(result[[k]])
    } else if (endsWith(  k, "_utc")) { result[[k]] <- as.POSIXct(result[[k]], tz = "UTC") }
  }


  #________________________________________________________
  # Try to simplify the data.frame.
  #________________________________________________________
  if (isTRUE(simplify)) {
    if (nrow(result) == 0) return (NULL)
    if (ncol(result) == 1) return (result[[1]])
    if (nrow(result) == 1) return (as.list(result))
  }

  return (result)
}


#______________________________________________________________________________
#' Create and run an INSERT statement.
#' @noRd
db_insert <- function (DB, table, err_code, ..., defaults = list()) {


  # Allow unnamed arguments, e.g. db_insert(DB, 'permissions', user_id, project_id)
  values <- named_dots(...)
  stopifnot(length(values) > 0)


  # Add in any relevant defaults
  stopifnot(is.list(defaults))
  values %<>% c(defaults[setdiff(names(defaults), names(values))])


  # Prevent SQL injection through table/column names.
  stopifnot(is_scalar_character(table))
  stopifnot(all(grepl("^[a-zA-Z_]+$", c(table, names(values)))))


  # Values with attribute sql=TRUE don't get bound as variables.
  values <- lapply(values, function (v) {
    if (is.null(v) || is.na(v)) structure("NULL", sql = TRUE) else v })
  static <- sapply(values, function (x) { isTRUE(attr(x, 'sql', exact = TRUE)) })
  params <- if (all(static)) NULL else unname(values[!static])
  sql    <- sprintf(
    fmt = "INSERT INTO %s (%s) VALUES (%s)",
    table,
    paste(collapse=", ", names(values)),
    paste(collapse=", ", ifelse(static, values, "?")) )

  return (db_query(DB, sql, err_code, params))
}


#______________________________________________________________________________
#' Create and run an UPDATE statement.
#' The `id` is the primary key for the row to be updated.
#' @noRd
db_update <- function (DB, table, id, err_code, ...) {


  # Allow unnamed arguments, e.g. db_update(DB, 'projects', project_id, title)
  values <- named_dots(...)
  stopifnot(length(values) > 0)


  # Prevent SQL injection through table/column names.
  stopifnot(is_scalar_integerish(id))
  stopifnot(is_scalar_character(table))
  stopifnot(all(grepl("^[a-zA-Z_]+$", c(table, names(values)))))


  # Confirm we'll be changing exactly one row.
  db_row_exists(DB, table, id)


  # Values with attribute sql=TRUE don't get bound as variables.
  values <- lapply(values, function (v) {
    if (is.null(v) || is.na(v)) structure("NULL", sql = TRUE) else v })
  static <- sapply(values, function (x) { isTRUE(attr(x, 'sql', exact = TRUE)) })
  params <- if (all(static)) list(id) else c(unname(values[!static]), list(id))
  values <- paste(names(values), ifelse(static, paste("=", values), "= ?"))
  values <- paste(collapse=", ", values)
  sql    <- sprintf("UPDATE %s SET %s WHERE ROWID = ?", table, values)

  return (db_query(DB, sql, err_code, params))
}



#______________________________________________________________________________
#' Check that a primary key exists in a table.
#' @noRd
db_row_exists <- function (DB, table, id, assert=TRUE) {

  stopifnot(is_scalar_integerish(id))
  stopifnot(is_scalar_character(table))
  stopifnot(isTRUE(grepl("^[a-z_]+$", table)))

  sql <- "SELECT COUNT(*) FROM %s WHERE ROWID = ?"
  sql <- sprintf(sql, table)
  n   <- db_query(DB, sql, "DRExis1", list(id))

  if (identical(n, 0L) && isTRUE(assert))
    stop_user("That item no longer exists. Please reload the page.")

  return (identical(n, 1L))
}


#______________________________________________________________________________
#' Does the database hold no users and no projects yet?
#' @noRd
db_is_empty <- function (DB) {
  n <- dbGetQuery(DB, "SELECT (SELECT COUNT(*) FROM users) + (SELECT COUNT(*) FROM projects)")[[1]]
  identical(as.integer(n), 0L)
}


#______________________________________________________________________________
#' Fill a new database with rbiom's example datasets as public projects.
#'
#' @param DB      The connection.
#' @param config  The server configuration.
#' @param pool    The worker pool that imports the datasets, or `NULL` to
#'                import them in this process.
#' @noRd
db_seed <- function (DB, config, pool = NULL) {

  REQ <- as.environment(list(
    DB      = DB,
    CONFIG  = config,
    SESSION = list(user_id = NULL, full_name = "atima") ))

  for (dataset in c('hmp50', 'gems')) {

    imported <- pool_call(pool, "work_seed", list(ctx = worker_ctx(config), dataset = dataset))

    db_transaction(DB, add_project(
      REQ        = REQ,
      imported   = imported,
      public_key = dataset ))

    log_event("info", "db_seed", dataset = dataset)
  }

  invisible(NULL)
}
