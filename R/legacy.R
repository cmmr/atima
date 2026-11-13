#______________________________________________________________________________
# Importing projects from an older atima.
#
# An administrator converts the old installation's database to a file once
# (`legacy_convert()`) and names that file when starting the server
# (`run(legacy = )`). A signed-in user then chooses the old installation,
# types the email address and password they had there, and picks the
# projects to bring over.
#
# What happens where:
#
#  * This file is the main process's part: the settings, the three routes,
#    the limit on wrong passwords, and the database rows of an imported
#    project.
#  * `R/legacy-worker.R` and the adapters (`R/legacy-atima2.R`) run in a
#    worker. Only there is the old database read, the password checked and
#    anything decrypted.
#
# The old password is needed for every request, because atima 2 encrypted
# each project with keys that only the password unlocks. It is held in
# memory for the length of one request and is never written to the
# database, the log or a file: it travels as a `secret()`, which neither
# prints nor deparses its contents.
#
# Importing twice makes no copy. `legacy_imports` remembers which old
# project became which new one. The first person to import a project gets
# it with the level they had (editor or viewer); anyone else who could open
# the old project and imports it later is added to that same project with
# their old level. That is how sharing carries over, although with
# OpenID Connect nobody exists here until they have signed in.
#______________________________________________________________________________


# Checks of an old password that may fail within `legacy_window` minutes,
# for one signed-in user and, separately, for one old account.
legacy_max_attempts <- 5L
legacy_window       <- 15L


#______________________________________________________________________________
#' Wrap a value that must not appear in a log, an error or a call stack.
#'
#' The value sits in an environment, which prints and deparses as
#' `<environment>` and still travels to a worker with a job's arguments.
#' @noRd
secret <- function (value) {
  env <- new.env(parent = emptyenv())
  env[['value']] <- value
  structure(env, class = "atima_secret")
}

#' The value inside a `secret()`.
#' @noRd
reveal <- function (x) {
  stopifnot(inherits(x, "atima_secret"))
  get("value", envir = x, inherits = FALSE)
}


#______________________________________________________________________________
#' Read the `legacy` setting of `run()`.
#'
#' @param x  A named character vector `c(<label> = <file>)`, or one string
#'           of `<label>=<file>` entries separated by `;` (the form the
#'           `ATIMA_LEGACY` environment variable takes), or `NULL`.
#' @return A named character vector of file paths.
#' @noRd
legacy_setting <- function (x) {

  if (is.null(x) || length(x) == 0) return (character(0))

  if (!is.character(x) || anyNA(x))
    stop("'legacy' must be a named character vector of files, c(<label> = <file>).")

  if (is.null(names(x)) && length(x) == 1) {
    entries <- trimws(strsplit(x, ";", fixed = TRUE)[[1]])
    entries <- entries[nzchar(entries)]
    cut     <- regexpr("=", entries, fixed = TRUE)
    if (any(cut < 2))
      stop("'legacy' must be '<label>=<file>' entries separated by ';'.")
    x <- stats::setNames(trimws(substring(entries, cut + 1)), trimws(substr(entries, 1, cut - 1)))
  }

  labels <- names(x)

  if (is.null(labels) || any(!nzchar(labels)) || any(nchar(labels) > 60) || anyDuplicated(labels))
    stop("Each 'legacy' file needs a label of its own, of at most 60 characters.")

  x
}


#______________________________________________________________________________
#' Check the files named by the `legacy` setting and describe each one.
#'
#' @param files  What `legacy_setting()` returned.
#' @return A list, named by source id, of `list(id, label, path, format)`.
#'         Stops with a message for the administrator if a file is missing,
#'         was not made by `legacy_convert()`, or needs a package that is
#'         not installed.
#' @noRd
legacy_register <- function (files) {

  sources <- list()

  for (label in names(files)) {

    path <- normalizePath(files[[label]], winslash = "/", mustWork = FALSE)

    if (!file.exists(path) || dir.exists(path))
      stop("The legacy file for '", label, "' does not exist: ", path)

    meta <- tryCatch(legacy_meta(path), error = function (e) NULL)

    adapter <- legacy_adapters()[[meta[['format']] %||% ""]]

    if (is.null(adapter) || !is_scalar_character(meta[['source_id']]))
      stop("The legacy file for '", label, "' was not made by atima::legacy_convert(): ", path)

    if (!has_package(adapter[['needs']]))
      stop(
        "Importing from '", label, "' needs the '", adapter[['needs']], "' package. ",
        "Install it with install.packages(\"", adapter[['needs']], "\") and start the server again." )

    id <- meta[['source_id']]

    if (hasName(sources, id))
      stop("The legacy files for '", sources[[id]][['label']], "' and '", label, "' are the same conversion.")

    sources[[id]] <- list(id = id, label = label, path = path, format = meta[['format']])
  }

  sources
}


#______________________________________________________________________________
#' What a converted file says about itself.
#' @return A named list: `format`, `source_id`, `converted_utc`.
#' @noRd
legacy_meta <- function (path) {
  con <- legacy_open(path)
  on.exit(dbDisconnect(con), add = TRUE)
  meta <- dbGetQuery(con, "SELECT key, value FROM meta")
  stats::setNames(as.list(meta[['value']]), meta[['key']])
}


#______________________________________________________________________________
#' The legacy source a request names.
#' @noRd
legacy_source <- function (REQ, source) {
  found <- REQ[['CONFIG']][['legacy']][[source]]
  if (is.null(found)) stop_not_found("That older installation is not available on this server.")
  found
}


#______________________________________________________________________________
#' Count a check of an old password before it is made.
#'
#' Called by a handler, whose transaction is committed before the worker
#' starts, so the count stands whatever becomes of the job. `legacy_settle()`
#' takes it back once the password has proved right. Counting first also
#' means that many requests sent at once cannot each see a clean record.
#'
#' @return The ids of the rows that were added. Stops with a 429 if the
#'         user, or the old account, has used up its attempts.
#' @noRd
legacy_charge <- function (DB, user_id, source, email) {

  db_query(DB, "DELETE FROM legacy_attempts WHERE attempt_utc < datetime('now', '-1 day')", "LChg1")

  account  <- as.character(sha256(paste(source[['id']], tolower(trimws(email)), sep = "\n")))
  subjects <- c(paste0("user:", user_id), paste0("account:", account))
  window   <- sprintf("-%i minutes", legacy_window)

  for (subject in subjects) {

    sql  <- "SELECT attempt_utc FROM legacy_attempts WHERE subject = ? AND attempt_utc > datetime('now', ?) ORDER BY attempt_utc"
    past <- db_query(DB, sql, "LChg2", list(subject, window), simplify = FALSE)

    if (nrow(past) >= legacy_max_attempts) {
      # Another try is possible once the oldest of the last five is forgotten.
      oldest <- past[['attempt_utc']][[nrow(past) - legacy_max_attempts + 1L]]
      wait   <- legacy_window - as.numeric(difftime(Sys.time(), oldest, units = "mins"))
      wait   <- max(1L, as.integer(ceiling(wait)))
      stop_http(429L, sprintf(
        "Too many wrong passwords. Please wait %i minute%s and try again.", wait, if (wait == 1) "" else "s" ))
    }
  }

  vapply(subjects, FUN.VALUE = numeric(1), function (subject) {
    as.numeric(db_query(DB, "INSERT INTO legacy_attempts (subject) VALUES (?)", "LChg3", list(subject))) })
}


#______________________________________________________________________________
#' Take back the count of a check that found the password right.
#' @noRd
legacy_settle <- function (DB, charge) {
  for (id in charge)
    db_query(DB, "DELETE FROM legacy_attempts WHERE legacy_attempt_id = ?", "LSet1", list(id))
  invisible(NULL)
}


#______________________________________________________________________________
#' The response to a wrong email address or password.
#'
#' Returned, not raised: an error would undo the transaction the response
#' is built in, and this one has nothing to undo. The same words answer an
#' unknown address and a wrong password.
#' @noRd
legacy_refused <- function (REQ, source) {

  sql  <- "SELECT COUNT(*) FROM legacy_attempts WHERE subject = ? AND attempt_utc > datetime('now', ?)"
  used <- db_query(REQ[['DB']], sql, "LRef1", list(
    paste0("user:", REQ[['SESSION']][['user_id']]), sprintf("-%i minutes", legacy_window) ))
  left <- max(0L, legacy_max_attempts - as.integer(used))

  error_response(REQ = REQ, e = http_condition(
    status  = 400L,
    code    = "wrong_credentials",
    message = paste0(
      "That email address and password do not match an account in ", source[['label']], ". ",
      if (left == 0) { sprintf("Please wait %i minutes before trying again.", legacy_window)
      } else         { sprintf("You can try %i more time%s.", left, if (left == 1) "" else "s") } )))
}


#______________________________________________________________________________
#' The project an old project was imported as, if it was.
#' @return A project_id or `NULL`.
#' @noRd
legacy_imported <- function (DB, source, old_project) {
  sql <- "SELECT project_id FROM legacy_imports WHERE source = ? AND old_project = ?"
  db_query(DB, sql, "LImp1", list(source[['id']], old_project))
}


#______________________________________________________________________________
#' The older installations this server can import from.
#' @return list(sources = list(list(id, label)))
#' @noRd
api_legacy_sources <- function (REQ) {
  sources <- unname(REQ[['CONFIG']][['legacy']])
  list(sources = lapply(sources, function (s) list(id = unbox(s[['id']]), label = unbox(s[['label']]))))
}


#______________________________________________________________________________
#' Check an old email address and password, and list that account's
#' projects.
#'
#' @return list(projects), each `list(id, title, created, level, status)`.
#'         `status` is `"new"`, `"shared"` (someone else has imported it;
#'         importing adds the caller to that project) or `"have"`.
#' @noRd
api_legacy_list <- function (REQ, source, email, password) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  source  <- legacy_source(REQ, source)
  charge  <- legacy_charge(DB, user_id, source, email)

  job(
    fn     = "work_legacy_list",
    args   = list(ctx = worker_ctx(REQ[['CONFIG']]), source = source[c("path", "format")], email = email, password = password),
    finish = function (result) {

      if (!isTRUE(result[['verified']])) return (legacy_refused(REQ, source))

      legacy_settle(DB, charge)

      if (!is.null(result[['error']])) return (legacy_error(REQ, result[['error']]))

      projects <- lapply(result[['projects']], function (p) {

        project_id <- legacy_imported(DB, source, p[['id']])
        status     <- "new"

        if (!is.null(project_id)) {
          sql    <- "SELECT COUNT(*) FROM permissions WHERE user_id = ? AND project_id = ?"
          status <- if (db_query(DB, sql, "ALLst1", list(user_id, project_id)) > 0) "have" else "shared"
        }

        list(
          id      = unbox(p[['id']]),
          title   = unbox(p[['title']]),
          created = unbox(substr(p[['created']] %||% NA_character_, 1, 10)),
          level   = unbox(if (isTRUE(p[['is_editor']])) "editor" else "viewer"),
          status  = unbox(status) )
      })

      log_event("info", "legacy_list", user_id = user_id, source = source[['id']], projects = length(projects))

      list(projects = projects)
    })
}


#______________________________________________________________________________
#' Import one project of an old account into the caller's project tree.
#'
#' @param project  The project's id in the old database.
#' @param inflate  As for an upload: scale counts that are not whole numbers.
#' @return list(status, tree_node). `status` is `"imported"`, `"added"` (the
#'         project had been imported by someone else, and the caller now
#'         has it too) or `"have"`.
#' @noRd
api_legacy_import <- function (REQ, source, email, password, project, inflate = FALSE) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  source  <- legacy_source(REQ, source)
  charge  <- legacy_charge(DB, user_id, source, email)

  # A project that is already here needs no data, only proof that this old
  # account could open it.
  fetch <- is.null(legacy_imported(DB, source, project))

  job(
    fn   = "work_legacy_import",
    args = list(
      ctx = worker_ctx(REQ[['CONFIG']]), source = source[c("path", "format")], email = email, password = password,
      project = project, fetch = fetch, inflate = inflate ),
    finish = function (result) {

      if (!isTRUE(result[['verified']])) return (legacy_refused(REQ, source))

      legacy_settle(DB, charge)

      if (!is.null(result[['error']])) return (legacy_error(REQ, result[['error']]))

      if (!isTRUE(result[['found']]))
        return (legacy_error(REQ, list(status = 404L, message = "That project is not one this account can open.")))

      level      <- if (isTRUE(result[['is_editor']])) "edit" else "view"
      project_id <- legacy_imported(DB, source, project)

      if (is.null(project_id) && is.null(result[['imported']]))
        return (legacy_error(REQ, list(status = 409L, message = "That project changed while it was being imported. Please try again.")))

      if (is.null(project_id)) {

        project_id <- add_project(REQ, result[['imported']])
        status     <- "imported"

        # add_project() makes the caller an editor. Someone who could only
        # view the old project can only view the new one.
        if (level == "view") {
          db_query(DB, "UPDATE permissions SET is_editor = 0 WHERE user_id = ? AND project_id = ?", "ALImp1", list(user_id, project_id))
          db_query(DB, "UPDATE projects SET editors = '[]' WHERE project_id = ?", "ALImp2", list(project_id))
        }

        created <- result[['created']]
        if (is_scalar_character(created) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", created))
          db_query(DB, "UPDATE projects SET created_utc = ? WHERE project_id = ?", "ALImp3", list(created, project_id))

        db_insert(
          DB = DB, table = "legacy_imports", err_code = "ALImp4",
          source = source[['id']], old_project = project, project_id = project_id, user_id = user_id )

      } else {

        sql <- "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?"
        own <- db_query(DB, sql, "ALImp5", list(user_id, project_id))

        if (is.null(own)) {
          update_permissions(DB, user_id, project_id, level)
          status <- "added"
        } else {
          # An old editor who so far only had view access here gets their level back.
          if (level == "edit" && !isTRUE(own)) update_permissions(DB, user_id, project_id, "edit")
          status <- "have"
        }
      }

      sql <- paste0(
        "SELECT * FROM permissions",
        " LEFT JOIN projects USING (project_id)",
        " WHERE user_id = ? AND project_id = ?" )
      row <- db_query(DB, sql, "ALImp6", list(user_id, project_id))

      log_event("info", "legacy_import", user_id = user_id, source = source[['id']], project_id = project_id, status = status)

      list(status = unbox(status), tree_node = tree_node(row))
    })
}


#______________________________________________________________________________
#' The response to an error a worker reported after it found the password
#' right. Returned, not raised, so that the transaction it is built in (and
#' with it `legacy_settle()`) is kept.
#' @noRd
legacy_error <- function (REQ, error) {
  error_response(REQ = REQ, e = http_condition(
    status  = error[['status']] %||% 500L,
    message = error[['message']],
    detail  = error[['detail']],
    code    = error[['code']] ))
}
