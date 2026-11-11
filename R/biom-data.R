#______________________________________________________________________________
# The front end's `BIOM` variable: everything the browser knows about the
# project that is open in a session.
#
# Part of it comes from the database (title, access key, permissions) and
# part is derived from the BIOM files by a worker (`biom_summary()`). The
# main process keeps the derived part of recently used projects in memory,
# so that opening or reloading a project it has seen does not need a worker.
#______________________________________________________________________________


# Most summaries kept in memory. One can be a few hundred kilobytes.
memo_max <- 50L


#______________________________________________________________________________
#' The in-memory store of project summaries, keyed by BIOM file ids.
#' @noRd
memo_new <- function () new.env(parent = emptyenv())

#' @noRd
memo_key <- function (REQ) {
  paste0(REQ[['SESSION']][['full_bf_id']], "_", REQ[['SESSION']][['rare_bf_id']])
}

#' @noRd
memo_get <- function (REQ) {
  memo <- REQ[['MEMO']]
  if (is.null(memo)) return (NULL)
  memo[[memo_key(REQ)]]
}

#' @noRd
memo_set <- function (REQ, data) {
  memo <- REQ[['MEMO']]
  if (is.null(memo)) return (invisible(NULL))
  if (length(memo) >= memo_max) rm(list = ls(memo), envir = memo)
  memo[[memo_key(REQ)]] <- data
  invisible(NULL)
}


#______________________________________________________________________________
#' Values for the front end's `BIOM` variable.
#'
#' @param REQ   The request, with its session loaded.
#' @param data  The summary of the session's BIOM files, from a worker.
#' @return list()
#' @noRd
session_biom <- function (REQ, data) {

  session       <- REQ[['SESSION']]
  permission_id <- session[['permission_id']]

  BIOM <- list(
    title       = unbox(session[['title']]),
    description = unbox(session[['description']]),
    access_key  = unbox(session[['access_key']]),
    project_key = unbox(session[['project_key']]),
    is_saved    = unbox(session[['is_saved']]),
    is_editor   = unbox(session[['is_editor']]),
    is_public   = unbox(session[['is_public']]) )

  # The project's node in the tree: its place in the user's own collections
  # if they have one, else the public tree.
  BIOM[['node_id']] <- unbox(ifelse(
    test = is.na(permission_id),
    yes  = paste0("G", session[['project_id']]),
    no   = paste0("P", permission_id) ))

  c(BIOM, data)
}


#______________________________________________________________________________
#' Remember a summary a worker just returned for the session's current
#' files, and build `BIOM` from it. For the `finish` part of jobs that
#' already had a reason to go to a worker.
#' @noRd
biom_reply <- function (REQ, data) {
  memo_set(REQ, data)
  session_biom(REQ, data)
}


#______________________________________________________________________________
#' Finish a handler that needs `BIOM` for the session's open project.
#'
#' @param REQ   The request, with its session loaded.
#' @param then  A function of `BIOM` that returns the handler's response.
#' @return What `then` returns if the summary is in memory; otherwise a
#'         `job()` that fetches the summary and then calls `then`.
#' @noRd
with_biom_data <- function (REQ, then) {

  data <- memo_get(REQ)
  if (!is.null(data)) return (then(session_biom(REQ, data)))

  job(
    fn     = "work_summary",
    args   = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]) ),
    finish = function (result) then(biom_reply(REQ, result[['data']])) )
}


#______________________________________________________________________________
#' Point the session's draft at new stored files, and reload the session.
#'
#' @param full,rare  `list(file, hash)` entries from a worker, or `NULL` to
#'                   leave that file as it is.
#' @noRd
update_draft <- function (REQ, full = NULL, rare = NULL) {

  DB       <- REQ[['DB']]
  draft_id <- REQ[['SESSION']][['draft_id']]

  if (!is.null(full))
    db_update(DB, "drafts", draft_id, "UDraf1", full_bf_id = register_biom_file(DB, full))

  if (!is.null(rare))
    db_update(DB, "drafts", draft_id, "UDraf2", rare_bf_id = register_biom_file(DB, rare))

  resume_session(REQ)

  invisible(NULL)
}
