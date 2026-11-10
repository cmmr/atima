#______________________________________________________________________________
# Errors.
#
# Two kinds of error reach the router:
#
#  * An `atima_http_error`, raised with `stop_http()` or one of its shorthands.
#    Its message was written for the user and is sent to the browser with the
#    given HTTP status.
#  * Anything else. The browser is told "Internal error" and nothing more.
#
# Either way the browser also gets a random error id, and the full details
# (original message, SQL, parameters, call stack) are written to the server
# log under that id.
#______________________________________________________________________________


#______________________________________________________________________________
#' Stop with a message that is safe to show to the user.
#'
#' @param status  The HTTP status code for the response.
#' @param ...     Pasted together to make the message.
#' @noRd
stop_http <- function (status, ...) {
  stop(structure(
    class = c("atima_http_error", "error", "condition"),
    list(message = paste0(...), call = NULL, status = as.integer(status)) ))
}

#' The request itself is wrong: a bad argument or an impossible action.
#' @noRd
stop_user <- function (...) stop_http(400L, ...)

#' There is no valid session.
#' @noRd
stop_unauthorized <- function (...) stop_http(401L, ...)

#' There is a session, but it may not do this.
#' @noRd
stop_forbidden <- function (...) stop_http(403L, ...)

#' The thing asked for does not exist.
#' @noRd
stop_not_found <- function (...) stop_http(404L, ...)


#______________________________________________________________________________
#' Run code whose failures are the user's to fix.
#'
#' rbiom stops with messages written for the person who chose the data and
#' the options ("Invalid `md` option(s): ..."). Wrapped in this, such an
#' error becomes a 400 instead of an anonymous "Internal error".
#'
#' @param message  What to tell the user went wrong.
#' @param code     The code to run.
#' @param detail   Append the original error message? Leave it out when the
#'                 message could name server files; it is logged instead.
#' @return The value of `code`.
#' @noRd
with_user_errors <- function (message, code, detail = TRUE) {
  tryCatch(
    expr  = code,
    error = function (e) {

      if (inherits(e, "atima_http_error")) stop(e)

      original <- gsub("\033\\[[0-9;]*[A-Za-z]", "", conditionMessage(e))

      if (detail) stop_user(message, " ", log_truncate(original, 500L))

      log_event("info", "user_error", message = message, detail = log_truncate(original, 2000L))
      stop_user(message)
    })
}


#______________________________________________________________________________
#' Stop because a database statement failed.
#'
#' The SQL and its parameters travel with the condition so that they can be
#' logged, but they are not part of the message.
#' @noRd
stop_db <- function (err_code, parent, sql = NULL, params = NULL) {
  stop(structure(
    class = c("atima_db_error", "error", "condition"),
    list(
      message  = sprintf("Database error (%s).", err_code),
      call     = NULL,
      err_code = err_code,
      detail   = conditionMessage(parent),
      sql      = sql,
      params   = params )))
}


#______________________________________________________________________________
#' Turn an error into the response for the browser, and log the details.
#'
#' @param e      The condition that was caught.
#' @param REQ    The request environment, if one had been built.
#' @param calls  The call stack at the point of the error, from
#'               `sys.calls()`.
#' @return A `response()` whose body is
#'         `{"error": {"message": <string>, "id": <string>}}`.
#' @noRd
error_response <- function (e, REQ = NULL, calls = NULL) {

  id <- random_string(8)

  if (inherits(e, "atima_http_error")) {
    status  <- e[['status']]
    message <- conditionMessage(e)
    level   <- "info"
  } else {
    status  <- 500L
    message <- "Internal error. If it happens again, please report the error id."
    level   <- "error"
  }

  params <- e[['params']]
  if (!is.null(params))
    params <- lapply(unname(as.list(params)), log_truncate, max = 200L)

  log_event(
    level    = level,
    event    = "error",
    id       = id,
    status   = status,
    method   = REQ[['METHOD']],
    path     = REQ[['ROUTE']][['path']] %||% REQ[['PATH']],
    user_id  = REQ[['SESSION']][['user_id']],
    message  = log_truncate(conditionMessage(e), 2000L),
    class    = class(e)[[1]],
    err_code = e[['err_code']],
    detail   = if (!is.null(e[['detail']])) log_truncate(e[['detail']], 2000L),
    sql      = if (!is.null(e[['sql']]))    log_truncate(e[['sql']],    2000L),
    params   = params,
    calls    = if (status >= 500L) format_calls(calls) )

  response(
    body   = list(error = list(message = unbox(message), id = unbox(id))),
    status = status )
}


#______________________________________________________________________________
#' The innermost calls of a call stack, one short string each.
#' @noRd
format_calls <- function (calls, n = 15L) {

  if (length(calls) == 0) return (NULL)

  calls <- vapply(calls, FUN.VALUE = character(1), function (call) {
    log_truncate(deparse(call, width.cutoff = 200L, nlines = 1L), 200L) })

  # Drop the condition-handling frames that sit below the failing call.
  drop  <- grepl("^(stop|stop_[a-z]+|\\.handleSimpleError|h|withCallingHandlers|tryCatch|tryCatchList|tryCatchOne|doTryCatch|value\\[\\[3L\\]\\])\\(", calls)
  calls <- calls[!drop]

  tail(calls, n)
}
