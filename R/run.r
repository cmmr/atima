#______________________________________________________________________________
#' Run the atima server
#'
#' Starts a web server that lets users upload BIOM files and explore them
#' with 'rbiom' plots in their browser. Projects are stored in an SQLite
#' database and a set of files under `data_dir`.
#'
#' The R session that calls `run()` answers requests and owns the database.
#' Everything that reads a BIOM file or calls 'rbiom' is done by a pool of
#' worker processes, so the server keeps answering while a plot is drawn.
#'
#' Every argument can also be set with an environment variable or an R
#' option. The first of these that is set is used:
#' \enumerate{
#'   \item the argument itself, e.g. `run(port = 8080)`
#'   \item the environment variable `ATIMA_<NAME>`, e.g. `ATIMA_PORT=8080`
#'   \item the R option `atima.<name>`, e.g. `options(atima.port = 8080)`
#'   \item the default shown below
#' }
#'
#' @param port        Port to listen on.
#' @param host        IP address to listen on. The default, `"127.0.0.1"`,
#'                    only accepts connections from this computer. Use
#'                    `"0.0.0.0"` to listen on all interfaces.
#' @param data_dir    Directory for the database and stored BIOM files. It
#'                    is created, and filled with two example projects, the
#'                    first time the server starts.
#' @param temp_dir    Directory for temporary files, including the figures
#'                    and exports that browsers download. It must not be
#'                    `data_dir`, or inside it: old files here are deleted.
#' @param workers     Number of worker processes, each of which runs one job
#'                    (a plot, an upload, an export, ...) at a time. The
#'                    default is half the available CPU cores, at least 1
#'                    and at most 4. With `workers = 1`, jobs run one after
#'                    another, which suits a single user.
#' @param max_cpus    CPU cores one job may use. The default, `NULL`,
#'                    divides the available cores among the workers.
#' @param time_limit  The longest a job may run, in seconds. A job that
#'                    takes longer is stopped and the user is told so.
#' @param cache_size_mb  Upper limit, in megabytes, for the cache of
#'                    computed results kept in `data_dir`. Half is for
#'                    atima's own cache and half for rbiom's.
#' @param session_hours  A session is closed, and its unsaved changes and
#'                    temporary files are deleted, when its browser tab has
#'                    not been heard from for this many hours.
#' @param guest_days  A guest (someone who has not signed in) is forgotten
#'                    after this many days without a visit, along with any
#'                    projects that only they could open.
#' @param max_upload_mb  Largest upload to accept, in megabytes.
#' @param smtp        A list of SMTP settings (`server`, `port`, `username`,
#'                    `password`, `fromaddr`, `ssl`) for account emails.
#'                    Accepted but not used yet: no email is sent, and new
#'                    accounts are created without email verification.
#' @param open        Open the app in a web browser once the server is up?
#'
#' @section Database:
#' The database is the file `sqlite.db` in `data_dir`. When a newer version
#' of atima needs to change its structure, the server first saves a copy as
#' `sqlite.db.v<N>.<date>.bak` in the same directory, then upgrades the
#' database in place.
#'
#' @section Jobs:
#' A request that needs a worker waits in a queue if all workers are busy.
#' A new plot, rarefaction or table page from a browser tab replaces that
#' tab's earlier request of the same kind if it is still waiting or running.
#' A job that passes `time_limit`, or is replaced, is interrupted; if it has
#' not stopped five seconds later, its worker process is ended and a new one
#' takes its place.
#'
#' @section Cleanup:
#' When the server starts, and every ten minutes after that, it deletes
#' closed and expired sessions, working copies that no session has open,
#' guests who have not returned, private projects that nobody has in their
#' project tree any more, stored files that nothing refers to, and old
#' temporary files. See `session_hours` and `guest_days`. Saved projects
#' that belong to a signed-in user are never deleted.
#'
#' @section Server log:
#' The server writes one line of JSON per request and per error to standard
#' error. An error shown in the browser carries a short id; the log line with
#' the same `id` has the details. To write the log to a file instead, set
#' `options(atima.log = "path/to/atima.log")` before calling `run()`.
#'
#' @return Does not return; the server runs until the R session is
#'         interrupted. It then cancels running jobs, stops the worker
#'         processes and closes the database.
#' @export
#' @examples
#' if (interactive()) {
#'   # Serve on http://127.0.0.1:8080 and keep data in a temporary directory.
#'   atima::run(data_dir = tempfile("atima_data_"))
#' }
run <- function(
    port          = 8080,
    host          = '127.0.0.1',
    data_dir      = tools::R_user_dir('atima', 'data'),
    temp_dir      = tempfile(pattern = 'atima_'),
    workers       = max(1, min(4, parallelly::availableCores() %/% 2)),
    max_cpus      = NULL,
    time_limit    = 60,
    cache_size_mb = 100,
    max_upload_mb = 50,
    session_hours = 24,
    guest_days    = 30,
    smtp          = NULL,
    open          = interactive() ) {

  message("Initializing Atima Server...")

  #______________________________________________
  # 1. Argument Resolution & Validation
  #
  explicits <- if (nargs() > 0) mget(names(match.call())[-1]) else list()

  find_arg <- function(param, cls) {

    val <- if (hasName(explicits, param)) { explicits[[param]]
    } else if (nzchar(x <- Sys.getenv(paste0('ATIMA_', toupper(param))))) { x
    } else if (!is.null(x <- getOption(paste0('atima.', param)))) { x
    } else if (param %in% formalArgs(run)) { get(param, parent.frame())
    } else { NULL }

    if (startsWith(param, 'smtp_') && is.null(val)) return (val)
    if (param == 'max_cpus'        && is.null(val)) return (val)

    if (is.null(val))     stop(param, ' cannot be NULL.')
    if (length(val) != 1) stop(param, ' must be a single value.')
    if (is.na(val))       stop(param, ' cannot be NA.')

    tryCatch(
      error = function (e) stop("Error with '", param, "' parameter: ", e),
      expr  = switch(
        EXPR = cls,
        'int'  = as.integer(as.vector(val)),
        'chr'  = as.character(as.vector(val)),
        'bool' = as.logical(as.vector(val)),
        stop('invalid class: ', cls)))
  }

  port          <- find_arg('port',          'int')
  host          <- find_arg('host',          'chr')
  data_dir      <- find_arg('data_dir',      'chr')
  temp_dir      <- find_arg('temp_dir',      'chr')
  time_limit    <- find_arg('time_limit',    'int')
  cache_size_mb <- find_arg('cache_size_mb', 'int')
  max_upload_mb <- find_arg('max_upload_mb', 'int')
  workers       <- find_arg('workers',       'int')
  max_cpus      <- find_arg('max_cpus',      'int')
  session_hours <- find_arg('session_hours', 'int')
  guest_days    <- find_arg('guest_days',    'int')
  open          <- find_arg('open',          'bool')

  if (is.null(smtp)) {
    smtp <- list(
      server   = find_arg('smtp_server',   'chr'),
      port     = find_arg('smtp_port',     'int'),
      username = find_arg('smtp_username', 'chr'),
      password = find_arg('smtp_password', 'chr'),
      fromaddr = find_arg('smtp_fromaddr', 'chr'),
      ssl      = find_arg('smtp_ssl',      'bool')
    )
    if (all(vapply(smtp, is.null, logical(1)))) smtp <- NULL
  }

  if (is.null(max_cpus))
    max_cpus <- max(1L, as.integer(availableCores()) %/% workers)

  for (param in c('workers', 'max_cpus', 'time_limit', 'session_hours', 'guest_days'))
    if (get(param) < 1) stop(param, ' must be at least 1.')

  cache_size_bytes <- cache_size_mb * 1024 * 1024
  max_upload_bytes <- max_upload_mb * 1024 * 1024


  #______________________________________________
  # 2. Environment & Database Setup
  #
  data_dir <- normalizePath(data_dir, winslash = "/", mustWork = FALSE)
  temp_dir <- normalizePath(temp_dir, winslash = "/", mustWork = FALSE)

  if (dirs_overlap(temp_dir, data_dir))
    stop('temp_dir must not be the same as data_dir, or inside it, or contain it.')

  if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)
  if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)

  message(' - Data Directory: ', data_dir)
  message(' - Temp Directory: ', temp_dir)


  config <- list(
    data_dir    = data_dir,
    temp_dir    = temp_dir,
    cache_size  = cache_size_bytes,
    time_limit  = time_limit,
    workers     = workers,
    max_cpus    = max_cpus,
    session_ttl = session_hours * 3600,
    guest_ttl   = guest_days * 86400,
    smtp        = smtp
  )

  for (subdir in file.path(data_dir, c('files', 'cache')))
    if (!dir.exists(subdir)) dir.create(subdir, recursive = TRUE)

  # Everything set up from here on is taken down again, in reverse order,
  # when the server stops: the cleanup timer, the workers (cancelling their
  # jobs), then the database.
  db <- db_open(data_dir)
  on.exit(db_close(db), add = TRUE, after = FALSE)

  storage_adopt_legacy(db, file.path(data_dir, 'files'))

  message(' - Starting ', workers, ' worker process', if (workers > 1) 'es', ' (', max_cpus, ' CPU', if (max_cpus > 1) 's', ' each)')
  pool <- pool_start(workers = workers, time_limit = time_limit)
  on.exit(pool_stop(pool), add = TRUE, after = FALSE)

  if (db_is_empty(db)) {
    message(' - Loading example projects')
    db_seed(db, config, pool)
  }

  app_state <- list(db = db, config = config, pool = pool, memo = memo_new())

  stop_cleanup <- cleanup_start(app_state)
  on.exit(stop_cleanup(), add = TRUE, after = FALSE)


  #______________________________________________
  # 3. HTTP Application Definition
  #

  app <- list(

    'onHeaders' = function(req) {

      tryCatch(
        error = function (e) { response(e$message, 500L) },
        expr  = {
          method <- toupper(req[['REQUEST_METHOD']])

          if (identical(method, "POST")) {

            len <- suppressWarnings(as.numeric(req$CONTENT_LENGTH))

            if (length(len) != 1 || is.na(len)) {
              response("Content-Length Required", 411L)
            }
            else if (isTRUE(len > max_upload_bytes)) {
              response("File Upload Size Too Large", 413L)
            }
            else {
              NULL
            }
          }
          else if (!identical(method, "GET")) {
            response('Method Not Allowed', 405L)
          }
          else {
            NULL # request is valid.
          }
        }
      )
    },

    # The answer is a response, or a promise of one while a worker is busy
    # with the request. Either way this returns at once.
    'call' = function(req) {
      handle_request(req, app_state)
    },

    'staticPaths' = list(
      '/www' = system.file(package = 'atima', 'www'),
      '/tmp' = temp_dir
    ),

    'staticPathOptions' = staticPathOptions(indexhtml = FALSE)
  )

  #______________________________________________
  # 4. Start Server
  #
  url <- local_url(host, port)
  message("Server listening on ", host, " port ", port, ". Open ", url)

  if (open) utils::browseURL(url)

  on.exit(message("Stopping the Atima server..."), add = TRUE, after = FALSE)

  httpuv::runServer(host, port, app)
}


#______________________________________________________________________________
#' Internal: URL a browser on this machine can use to reach the server.
#'
#' Wildcard listen addresses ("0.0.0.0", "::") are not valid destinations, so
#' they are mapped to the loopback address. IPv6 literals get brackets.
#' @noRd
local_url <- function (host, port) {
  if (host %in% c('0.0.0.0', ''))  host <- '127.0.0.1'
  if (host %in% c('::', '[::]'))   host <- '::1'
  if (grepl(':', host, fixed = TRUE) && !startsWith(host, '['))
    host <- paste0('[', host, ']')
  sprintf("http://%s:%d", host, as.integer(port))
}


#______________________________________________________________________________
#' Internal: Serves customized index.html
#' @noRd
static_index_html <- local({

  atima_version  <- as.character(packageVersion("atima"))
  rbiom_version  <- as.character(packageVersion("rbiom"))
  copyright_year <- substr(Sys.Date(), 1, 4)

  html_path <- system.file(package = "atima", "www", "index.html")
  if (!file.exists(html_path)) {
    html <- "<html><body>Error: index.html not found.</body></html>"
  } else {
    html <- readChar(html_path, file.info(html_path)$size)
    html <- sub("{{atima_version}}",  atima_version,  html, fixed = TRUE)
    html <- sub("{{rbiom_version}}",  rbiom_version,  html, fixed = TRUE)
    html <- sub("{{copyright_year}}", copyright_year, html, fixed = TRUE)
  }

  response(
    status  = 200L,
    body    = html,
    headers = list(
      'Content-Type'           = "text/html; charset=utf-8",
      'X-Content-Type-Options' = "nosniff",
      'X-Frame-Options'        = "DENY"
    )
  )
})


#______________________________________________________________________________
#' Internal: route handler for the pages that load the single-page app.
#' @noRd
serve_index <- function (REQ, access_key = NULL) {
  static_index_html
}
