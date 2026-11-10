#______________________________________________________________________________
#' Run the atima server
#'
#' Starts a web server that lets users upload BIOM files and explore them
#' with 'rbiom' plots in their browser. Projects are stored in an SQLite
#' database and a set of files under `data_dir`.
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
#'                    and exports that browsers download.
#' @param workers,max_cpus,time_limit  Reserved for the worker pool: the
#'                    number of worker processes, the CPU cores one job may
#'                    use, and the longest a job may run, in seconds. They
#'                    are checked but not used yet; all requests currently
#'                    run one at a time in the main R process.
#' @param cache_size_mb  Upper limit, in megabytes, for the cache of
#'                    computed results kept in `data_dir`.
#' @param max_upload_mb  Largest upload to accept, in megabytes.
#' @param smtp        A list of SMTP settings (`server`, `port`, `username`,
#'                    `password`, `fromaddr`, `ssl`) for account emails.
#'                    Accepted but not used yet: no email is sent, and new
#'                    accounts are created without email verification.
#' @param open        Open the app in a web browser once the server is up?
#' 
#' @return Does not return; the server runs until the R session is
#'         interrupted.
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
    workers       = parallelly::availableCores(),
    max_cpus      = parallelly::availableCores(),
    time_limit    = 60,
    cache_size_mb = 100,
    max_upload_mb = 50,
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
  max_cpus      <- find_arg('max_cpus',      'int')
  workers       <- find_arg('workers',       'int')
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
  
  cache_size_bytes <- cache_size_mb * 1024 * 1024
  max_upload_bytes <- max_upload_mb * 1024 * 1024
  
  
  #______________________________________________
  # 2. Environment & Database Setup
  #
  data_dir <- normalizePath(data_dir, winslash = "/", mustWork = FALSE)
  temp_dir <- normalizePath(temp_dir, winslash = "/", mustWork = FALSE)
  
  if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)
  if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)
  
  message(' - Data Directory: ', data_dir)
  message(' - Temp Directory: ', temp_dir)
  
  
  config <- list(
    data_dir   = data_dir,
    temp_dir   = temp_dir,
    cache_size = cache_size_bytes,
    time_limit = time_limit,
    max_cpus   = max_cpus,
    smtp       = smtp
  )
  
  db_init(config)
  
  
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
    
    'call' = function(req) {
      
      tryCatch(
        error = function (e) { response(as.character(e), 500L) },
        expr  = {
          
          path <- req[['PATH_INFO']]
          
          # Matches '/', '/hmp50', and '/hmp50/', but NOT '/hmp50/biom.gz'
          if (length(strsplit(path, '/', fixed = TRUE)[[1]]) <= 2)
            return(static_index_html)
          
          if (is.function(req[['rook.input']]$read))
            req$RAW_ARGS <- req[['rook.input']]$read()
          
          req <- c(as.list(req), list(CONFIG = config))
          
          simple_handler(req)
        }
      )
      
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
#' Internal: Parse one HTTP request and pass it to the GET or POST handler.
#' @noRd
simple_handler <- function(request) {
  
  args <- list()
  if (!is.null(request[['RAW_ARGS']])) {
    args <- webutils::parse_http(request[['RAW_ARGS']], request[['CONTENT_TYPE']]) 
  }
  if (isTRUE(nzchar(request[['QUERY_STRING']]))) {
    args <- c(args, webutils::parse_query(request[['QUERY_STRING']])) 
  }
  
  cookies <- list()
  if (isTRUE(nzchar(request[['HTTP_COOKIE']]))) {
    raw_cookies <- strsplit(request[['HTTP_COOKIE']], ";", fixed = TRUE)[[1]]
    for (cookie in raw_cookies) {
      parts <- trimws(strsplit(cookie, "=", fixed = TRUE)[[1]])
      if (length(parts) >= 2) {
        val <- if (length(parts) > 2) paste(parts[-1], collapse = '=') else parts[2]
        cookies[[parts[1]]] <- val
      }
    }
  }
  
  auth_token  <- cookies[['auth_token']]
  session_key <- unname(request[['HEADERS']]['x-session-key'])
  
  if (is.null(auth_token) || nchar(auth_token) != 64L) auth_token  <- NULL
  if (!isTRUE(grepl("^[a-zA-Z0-9]+$", session_key)))   session_key <- NULL
  
  REQ <- as.environment(list(
    ARGS   = args,
    PATH   = request[['PATH_INFO']],
    CONFIG = request[['CONFIG']],
    URL    = paste0("http://", request[['HTTP_HOST']]),
    CLIENT = list(
      auth_token  = auth_token, 
      session_key = session_key,
      ip_address  = request[['REMOTE_ADDR']] 
    )
  ))
  
  REQ[['DB']] <- db_connect(REQ[['CONFIG']][['data_dir']])
  on.exit(db_close(REQ[['DB']]), add = TRUE)
  
  resp <- switch(
    EXPR = request[['REQUEST_METHOD']],
    POST = handle_post_request(REQ),
    GET  = handle_get_request(REQ),
    response('Method Not Allowed', 405L)
  )
  
  if (!inherits(resp, "response"))
    resp <- response(resp)
  
  return (resp)
}
