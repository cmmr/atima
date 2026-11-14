#______________________________________________________________________________
# Stopping the server.
#
# The server stops when the R process is interrupted (Ctrl-C, SIGINT, or a
# container's stop signal). R delivers an interrupt to whatever code is
# running at that moment. While the server idles that is the event loop in
# `serve()`, which then ends. But on a busy server it is usually a callback
# of the event loop (a request handler, the end of a job), and there the
# interrupt only ends that one callback: the loop that called it carries on,
# and the server would keep answering as if nothing had been asked of it.
#
# So every callback the server gives the event loop runs inside
# `interruptible()`, which turns an interrupt into a request to stop that
# `serve()` sees when the callback returns.
#______________________________________________________________________________

shutdown <- new.env(parent = emptyenv())
shutdown$requested <- FALSE


#______________________________________________________________________________
#' Run a callback of the event loop. If it is interrupted, note that the
#' server has been asked to stop.
#'
#' @param expr       The callback's code.
#' @param otherwise  What to return if it was interrupted.
#' @noRd
interruptible <- function (expr, otherwise = NULL) {
  tryCatch(expr, interrupt = function (e) {
    shutdown$requested <- TRUE
    otherwise
  })
}


#______________________________________________________________________________
#' The answer to a request that was cut off by the server stopping.
#' @noRd
stopping_response <- function () {
  response(
    status = 503L,
    body   = list(error = list(message = unbox("The server is shutting down."), id = unbox("shutdown"))) )
}


#______________________________________________________________________________
#' Serve requests until the server is asked to stop.
#'
#' @param host,port  Where to listen.
#' @param app        The httpuv application.
#' @return `NULL`, once an interrupt has arrived: either here, while idle
#'         (it then passes on to the caller, as an interrupt does), or in a
#'         callback, which `interruptible()` has noted.
#' @noRd
serve <- function (host, port, app) {

  server <- httpuv::startServer(host, port, app)
  on.exit(httpuv::stopServer(server), add = TRUE)

  while (!shutdown$requested) httpuv::service(250)

  invisible(NULL)
}
