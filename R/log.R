#______________________________________________________________________________
#' Write one event to the server log.
#'
#' The log is one JSON object per line. It goes to `stderr()` unless the R
#' option `atima.log` names a file (appended to) or holds a connection.
#' Nothing written here is ever sent to a browser, so it is the place for
#' SQL text, bound parameters and call stacks.
#'
#' @param level  `"info"`, `"warn"` or `"error"`.
#' @param event  A short name for what happened, e.g. `"request"`.
#' @param ...    Named fields to record. `NULL` fields are dropped.
#' @return `NULL`, invisibly.
#' @noRd
log_event <- function (level, event, ...) {

  fields <- list(...)
  fields <- fields[!vapply(fields, is.null, logical(1))]

  entry <- c(
    list(
      time  = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
      level = level,
      event = event ),
    fields )

  line <- tryCatch(
    expr  = toJSON(entry, auto_unbox = TRUE, null = "null", na = "null", force = TRUE),
    error = function (e) toJSON(list(
      time = entry[['time']], level = "error", event = "log_failure",
      message = conditionMessage(e) ), auto_unbox = TRUE) )

  dest <- getOption("atima.log", default = stderr())

  if (is.character(dest)) { cat(line, "\n", sep = "", file = dest, append = TRUE) }
  else                    { cat(line, "\n", sep = "", file = dest)                }

  invisible(NULL)
}


#______________________________________________________________________________
#' Shorten a value so that one log line stays readable.
#' @noRd
log_truncate <- function (x, max = 500L) {
  x <- paste(as.character(x), collapse = " ")
  if (nchar(x) > max) x <- paste0(substr(x, 1, max), "...")
  return (x)
}
