#______________________________________________________________________________
# The health check: `GET /api/health`.
#
# Whatever keeps the server running (a container's health check, a load
# balancer, a monitor) asks this to learn whether the server can do its work,
# not merely whether the port is open.
#______________________________________________________________________________


#______________________________________________________________________________
#' Can the server do its work?
#'
#' It can when the database answers a query and the worker pool has not been
#' stopped. The request needs no session and makes none: no guest, no cookie,
#' nothing written.
#'
#' @return A response: 200 `{"status": "ok"}`, or 503 `{"status":
#'         "unavailable"}`. Neither says what is wrong; the server log does.
#' @noRd
api_health <- function (REQ) {

  database <- tryCatch(
    expr  = { db_query(REQ[['DB']], "SELECT COUNT(*) FROM sqlite_master", "Health1"); TRUE },
    error = function (e) FALSE )

  # Without a pool (as in most tests) jobs run in this process.
  workers <- !isTRUE(REQ[['POOL']][['stopped']])

  ok <- database && workers

  if (!ok)
    log_event("error", "unhealthy", database = database, workers = workers)

  response(
    body    = list(status = unbox(if (ok) "ok" else "unavailable")),
    status  = if (ok) 200L else 503L,
    headers = list('Cache-Control' = "no-store") )
}
