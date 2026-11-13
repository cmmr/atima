#______________________________________________________________________________
# The worker's side of the legacy import (see `R/legacy.R`).
#
# A legacy source is a file made by `legacy_convert()` from the database of
# an older atima. Its `meta` table names its format, and each format has an
# adapter: three functions that verify an old email address and password,
# list that account's projects, and rebuild one of them.
#
#   verify(con, email, password)  ->  NULL, or the account (with whatever
#                                     keys the password unlocked)
#   projects(con, account)        ->  list of list(id, title, created,
#                                     is_editor, ...)
#   fetch(con, project, dir)      ->  list(biom, file, depth)
#
# The password arrives wrapped (`secret()`), is unwrapped only here, and
# never leaves this process: results carry no password and no key, and
# every error is reduced to a message that cannot contain one.
#______________________________________________________________________________


#______________________________________________________________________________
#' The adapters, by format name. `needs` is a package the adapter cannot
#' work without.
#' @noRd
legacy_adapters <- function () {
  list(
    atima2 = list(
      needs    = "bcrypt",
      verify   = atima2_verify,
      projects = atima2_projects,
      fetch    = atima2_fetch ))
}


#______________________________________________________________________________
#' Open a legacy source for reading only.
#' @noRd
legacy_open <- function (path) {
  dbConnect(SQLite(), dbname = path, flags = RSQLite::SQLITE_RO, synchronous = NULL)
}


#______________________________________________________________________________
#' Verify an old account and run `code(adapter, con, account)` for it.
#'
#' @param source  `list(path, format)`.
#' @return `list(verified = FALSE)` if the email address and password do not
#'         match, otherwise whatever `code` returns. An error meant for the
#'         user that is raised after the password was found right is
#'         returned as `list(verified = TRUE, error = list(status, message,
#'         code))` instead of being raised, so that the caller can tell a
#'         wrong password from a project that cannot be read.
#' @noRd
legacy_session <- function (source, email, password, code) {

  adapter <- legacy_adapters()[[source[['format']]]]

  # Nothing below may raise an error that carries its arguments or a call
  # stack to the log, because the password is among them.
  guarded <- function (expr) {
    tryCatch(
      expr             = expr,
      atima_http_error = function (e) e,
      error            = function (e) http_condition(
        status  = 500L,
        message = "The old database could not be read. Please report this to the administrator.",
        detail  = paste0(class(e)[[1]], ": ", log_truncate(conditionMessage(e), 300L)) ))
  }

  con <- legacy_open(source[['path']])
  on.exit(dbDisconnect(con), add = TRUE)

  account <- guarded(adapter[['verify']](con, tolower(trimws(email)), reveal(password)))

  if (inherits(account, "condition")) stop(account)
  if (is.null(account))               return (list(verified = FALSE))

  result <- guarded(code(adapter, con, account))

  if (inherits(result, "condition"))
    return (list(verified = TRUE, error = list(
      status  = result[['status']],
      message = conditionMessage(result),
      detail  = result[['detail']],
      code    = result[['code']] )))

  c(list(verified = TRUE), result)
}


#______________________________________________________________________________
#' List the projects an old account can open.
#'
#' @return `list(verified, projects)`; each project is
#'         `list(id, title, created, is_editor)`.
#' @noRd
work_legacy_list <- function (ctx, source, email, password) {

  worker_init(ctx)

  legacy_session(source, email, password, function (adapter, con, account) {
    projects <- adapter[['projects']](con, account)
    list(projects = lapply(projects, `[`, c("id", "title", "created", "is_editor")))
  })
}


#______________________________________________________________________________
#' Import one project of an old account.
#'
#' @param project  The project's id in the old database.
#' @param fetch    Rebuild and store the project's data? `FALSE` when the
#'                 project was imported before and the caller only needs to
#'                 know that this account may open it.
#' @param inflate  As for `work_import()`.
#' @return `list(verified, found, title, created, is_editor, imported)`.
#'         `found` is `FALSE` if the account has no such project;
#'         `imported` is what `work_import()` returns, when `fetch` is set.
#' @noRd
work_legacy_import <- function (ctx, source, email, password, project, fetch = TRUE, inflate = FALSE) {

  worker_init(ctx)

  legacy_session(source, email, password, function (adapter, con, account) {

    projects <- adapter[['projects']](con, account)
    match    <- Filter(function (p) identical(p[['id']], project), projects)

    if (length(match) == 0) return (list(found = FALSE))

    old    <- match[[1]]
    result <- c(list(found = TRUE), old[c("title", "created", "is_editor")])

    if (!fetch) return (result)

    dir <- tempfile("atima_legacy_")
    dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)

    fetched <- adapter[['fetch']](con, old, dir)

    imported <- import_biom(
      ctx       = ctx,
      full_biom = fetched[['biom']],
      orig      = fetched[['file']],
      title     = old[['title']],
      inflate   = inflate,
      depth     = fetched[['depth']] )

    c(result, list(imported = imported))
  })
}
