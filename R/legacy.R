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
#  * This file is the main process's part: the settings, the routes, the
#    limit on wrong passwords, the batches that import in the background,
#    and the database rows of an imported project.
#  * `R/legacy-worker.R` and the adapters (`R/legacy-atima2.R`) run in a
#    worker. Only there is the old database read, the password checked and
#    anything decrypted.
#
# The old password is needed for every project, because atima 2 encrypted
# each one with keys that only the password unlocks. It is held in memory,
# for the length of a request or of a running import, and is never written
# to the database, the log or a file: it travels as a `secret()`, which
# neither prints nor deparses its contents.
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
# Imports run in the background.
#
# Someone with many projects, or large ones, should not have to keep a page
# open, or wait, while they are copied. So "import these" is one request
# that starts a batch and returns. The main process then gives the batch's
# projects to the worker pool one at a time (one per person, so that the
# workers stay free for everyone's figures), records each as it arrives,
# and answers "how far along is it" whenever a browser asks.
#
# A batch lives in the main process's memory only, with the old password
# inside it as a `secret()`, for as long as it has projects left to import.
# When the last one is done, or the batch is cancelled, the password is
# dropped. A restart forgets every batch; what was imported stays, and the
# rest can be started again.
#______________________________________________________________________________


# Longest one project of a batch may take, in seconds. More than a request
# gets, because nobody is waiting on it and old projects can be large.
legacy_time_limit <- 900

# How often a project is offered to the pool again when its queue is full,
# and the seconds between tries.
legacy_retries    <- 120L
legacy_retry_wait <- 5


#______________________________________________________________________________
#' Where the running server keeps its import batches, by user id.
#' @noRd
legacy_state <- function () new.env(parent = emptyenv())


#______________________________________________________________________________
#' A user's batch, or `NULL`.
#' @noRd
legacy_batch <- function (state, user_id) {
  if (is.null(state)) return (NULL)
  state[[as.character(user_id)]]
}

#' Does a batch still have projects to import?
#' @noRd
legacy_active <- function (batch) {
  !is.null(batch) && any(vapply(batch$items, function (item) item$state %in% c("queued", "running"), logical(1)))
}


#______________________________________________________________________________
#' Start importing projects of an old account, in the background.
#'
#' @param projects  The projects' ids in the old database.
#' @param inflate   As for an upload: scale counts that are not whole
#'                  numbers. Without it such a project is left with the
#'                  state `needs_scaling` and the warning to show.
#' @return As `api_legacy_status()`.
#' @noRd
api_legacy_start <- function (REQ, source, email, password, projects, inflate = FALSE) {

  DB      <- REQ[['DB']]
  state   <- REQ[['LEGACY']]
  user_id <- REQ[['SESSION']][['user_id']]
  source  <- legacy_source(REQ, source)

  if (legacy_active(legacy_batch(state, user_id)))
    stop_http(409L, "An import is already running. Wait for it to finish, or cancel it.")

  charge <- legacy_charge(DB, user_id, source, email)

  # Checking the password also says which of the projects asked for this
  # account can open, and what they are called.
  job(
    fn     = "work_legacy_list",
    args   = list(ctx = worker_ctx(REQ[['CONFIG']]), source = source[c("path", "format")], email = email, password = password),
    finish = function (result) {

      if (!isTRUE(result[['verified']])) return (legacy_refused(REQ, source))

      legacy_settle(DB, charge)

      if (!is.null(result[['error']])) return (legacy_error(REQ, result[['error']]))

      if (legacy_active(legacy_batch(state, user_id)))
        return (legacy_error(REQ, list(status = 409L, message = "An import is already running.")))

      known  <- result[['projects']]
      names(known) <- vapply(known, function (p) p[['id']], character(1))
      chosen <- known[intersect(projects, names(known))]

      if (length(chosen) == 0)
        return (legacy_error(REQ, list(status = 404L, message = "None of those projects is one this account can open.")))

      batch <- new.env(parent = emptyenv())

      batch$user_id   <- user_id
      batch$full_name <- REQ[['SESSION']][['full_name']]
      batch$source    <- source
      batch$email     <- email
      batch$password  <- password
      batch$inflate   <- isTRUE(inflate)
      batch$items     <- lapply(chosen, function (p) c(p[c("id", "title")], list(state = "queued", message = NULL, tries = 0L)))

      state[[as.character(user_id)]] <- batch

      log_event("info", "legacy_start", user_id = user_id, source = source[['id']], projects = length(chosen))

      # After this request has been answered and its transaction closed.
      app <- list(db = DB, config = REQ[['CONFIG']], pool = REQ[['POOL']])
      later::later(function () legacy_advance(app, batch), 0)

      api_legacy_status(REQ)
    })
}


#______________________________________________________________________________
#' How the caller's import is getting on.
#'
#' @param tree  Include the caller's project tree? A page asks for it when
#'              a project has arrived since it last looked.
#' @return `list(active, source, projects, tree)`. Each project is
#'         `list(id, title, state, message)` with `state` one of `queued`,
#'         `running`, `imported`, `added` (someone else had imported it; the
#'         caller now has it too), `have`, `needs_scaling`, `failed` or
#'         `cancelled`. With no batch, `projects` is empty.
#' @noRd
api_legacy_status <- function (REQ, tree = FALSE) {

  batch <- legacy_batch(REQ[['LEGACY']], REQ[['SESSION']][['user_id']])

  if (is.null(batch))
    return (list(active = unbox(FALSE), projects = list()))

  list(
    active   = unbox(legacy_active(batch)),
    source   = unbox(batch$source[['label']]),
    projects = lapply(unname(batch$items), function (item) list(
      id      = unbox(item$id),
      title   = unbox(item$title),
      state   = unbox(item$state),
      message = unbox(item$message %||% NA_character_) )),
    tree     = if (isTRUE(tree)) tree_data(REQ) )
}


#______________________________________________________________________________
#' Stop the caller's import. The project being imported at this moment is
#' finished; the ones still waiting are not started.
#' @return As `api_legacy_status()`.
#' @noRd
api_legacy_cancel <- function (REQ) {

  batch <- legacy_batch(REQ[['LEGACY']], REQ[['SESSION']][['user_id']])

  if (!is.null(batch)) {
    for (id in names(batch$items))
      if (batch$items[[id]]$state == "queued") batch$items[[id]]$state <- "cancelled"
    if (!legacy_active(batch)) batch$password <- NULL
  }

  api_legacy_status(REQ)
}


#______________________________________________________________________________
#' Give the next project of a batch to the pool, or end the batch.
#'
#' @param app  `list(db, config, pool)`. Without a pool the project is
#'             imported in this process, which is how most tests run.
#' @noRd
legacy_advance <- function (app, batch) {

  waiting <- Filter(function (item) item$state == "queued", batch$items)

  if (length(waiting) == 0 || is.null(batch$password)) {
    batch$password <- NULL
    log_event("info", "legacy_done", user_id = batch$user_id, source = batch$source[['id']])
    return (invisible(NULL))
  }

  id <- waiting[[1]]$id
  batch$items[[id]]$state <- "running"

  args <- list(
    ctx      = worker_ctx(app[['config']]),
    source   = batch$source[c("path", "format")],
    email    = batch$email,
    password = batch$password,
    project  = id,
    # A project that is already here needs no data, only proof that this
    # old account could open it.
    fetch    = is.null(legacy_imported(app[['db']], batch$source, id)),
    inflate  = batch$inflate )

  settle <- function (outcome) {

    # The pool's queue was full, or this person has too many jobs of their
    # own: wait, and offer the project again.
    if (inherits(outcome, "atima_http_error") && outcome[['status']] %in% c(503L, 429L) && batch$items[[id]]$tries < legacy_retries) {
      batch$items[[id]]$tries <- batch$items[[id]]$tries + 1L
      batch$items[[id]]$state <- "queued"
      later::later(function () legacy_advance(app, batch), legacy_retry_wait)
      return (invisible(NULL))
    }

    legacy_record(app, batch, id, outcome)

    # Nothing left to do: the password is not needed a moment longer.
    if (!legacy_active(batch)) batch$password <- NULL

    later::later(function () legacy_advance(app, batch), 0)
    invisible(NULL)
  }

  if (is.null(app[['pool']])) {
    settle(tryCatch(run_inline("work_legacy_import", args), error = function (e) e))

  } else {
    promises::then(
      promise     = pool_submit(app[['pool']], "work_legacy_import", args, time_limit = max(legacy_time_limit, app[['pool']]$time_limit), user_id = batch$user_id),
      onFulfilled = settle,
      onRejected  = settle )
  }

  invisible(NULL)
}


#______________________________________________________________________________
#' Record the outcome of one project of a batch: the rows of the imported
#' project, and the state the browser is shown.
#'
#' @param outcome  What `worker_run()` returned, or the error the job ended
#'                 with.
#' @noRd
legacy_record <- function (app, batch, id, outcome) {

  DB <- app[['db']]

  # Anything that goes wrong becomes this project's state. An error the
  # user can read is shown; any other is logged under an id.
  failed <- function (e) {

    if (inherits(e, "atima_http_error") && identical(e[['code']], "confirm_inflate"))
      return (list(state = "needs_scaling", message = conditionMessage(e)))

    if (inherits(e, "atima_http_error") && e[['status']] < 500L)
      return (list(state = "failed", message = conditionMessage(e)))

    error_id <- random_string(8)

    log_event(
      level   = "error",
      event   = "legacy_import_failed",
      id      = error_id,
      user_id = batch$user_id,
      source  = batch$source[['id']],
      old_project = id,
      message = log_truncate(conditionMessage(e), 2000L),
      detail  = if (!is.null(e[['detail']])) log_truncate(e[['detail']], 2000L) )

    list(state = "failed", message = paste0(
      if (inherits(e, "atima_http_error")) conditionMessage(e) else "This project could not be imported.",
      " (Error id: ", error_id, ")" ))
  }

  done <- tryCatch(error = failed, expr = {

    if (inherits(outcome, "condition")) stop(outcome)

    result <- job_value(outcome)

    if (!isTRUE(result[['verified']]))
      stop_http(500L, "The old account's password was no longer accepted.")

    if (!is.null(result[['error']]))
      stop(http_condition(
        result[['error']][['status']] %||% 500L, result[['error']][['message']],
        result[['error']][['detail']], result[['error']][['code']] ))

    if (!isTRUE(result[['found']]))
      stop_user("This is not a project the old account can open.")

    db_transaction(DB, legacy_adopt(DB, batch, id, result))
  })

  batch$items[[id]]$state   <- done[['state']]
  batch$items[[id]]$message <- done[['message']]

  invisible(NULL)
}


#______________________________________________________________________________
#' Make an imported project the user's: create it, or, if someone else
#' imported it first, add the user to that one.
#'
#' @param result  What `work_legacy_import()` returned.
#' @return `list(state)`: `imported`, `added` or `have`.
#' @noRd
legacy_adopt <- function (DB, batch, id, result) {

  user_id    <- batch$user_id
  source     <- batch$source
  level      <- if (isTRUE(result[['is_editor']])) "edit" else "view"
  project_id <- legacy_imported(DB, source, id)

  if (is.null(db_query(DB, "SELECT user_id FROM users WHERE user_id = ?", "LAdo1", list(user_id))))
    stop_user("The account that started this import no longer exists.")

  if (is.null(project_id) && is.null(result[['imported']]))
    stop_http(409L, "This project changed while it was being imported. Please try again.")

  if (is.null(project_id)) {

    owner      <- list(DB = DB, SESSION = list(user_id = user_id, full_name = batch$full_name))
    project_id <- add_project(owner, result[['imported']])
    state      <- "imported"

    # add_project() makes the user an editor. Someone who could only view
    # the old project can only view the new one.
    if (level == "view") {
      db_query(DB, "UPDATE permissions SET is_editor = 0 WHERE user_id = ? AND project_id = ?", "LAdo2", list(user_id, project_id))
      db_query(DB, "UPDATE projects SET editors = '[]' WHERE project_id = ?", "LAdo3", list(project_id))
    }

    created <- result[['created']]
    if (is_scalar_character(created) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", created))
      db_query(DB, "UPDATE projects SET created_utc = ? WHERE project_id = ?", "LAdo4", list(created, project_id))

    db_insert(
      DB = DB, table = "legacy_imports", err_code = "LAdo5",
      source = source[['id']], old_project = id, project_id = project_id, user_id = user_id )

  } else {

    sql <- "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?"
    own <- db_query(DB, sql, "LAdo6", list(user_id, project_id))

    if (is.null(own)) {
      update_permissions(DB, user_id, project_id, level)
      state <- "added"
    } else {
      # An old editor who so far only had view access here gets their level back.
      if (level == "edit" && !isTRUE(own)) update_permissions(DB, user_id, project_id, "edit")
      state <- "have"
    }
  }

  log_event("info", "legacy_import", user_id = user_id, source = source[['id']], project_id = project_id, status = state)

  list(state = state)
}


#______________________________________________________________________________
#' The response to an error a worker reported after it found the password
#' right, or to a request that cannot be met. Returned, not raised, so that
#' the transaction it is built in (and with it `legacy_settle()`) is kept.
#' @noRd
legacy_error <- function (REQ, error) {
  error_response(REQ = REQ, e = http_condition(
    status  = error[['status']] %||% 500L,
    message = error[['message']],
    detail  = error[['detail']],
    code    = error[['code']] ))
}
