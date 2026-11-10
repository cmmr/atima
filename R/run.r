#______________________________________________________________________________
#' Run the Atima Server
#'
#' Starts the web server with fair scheduling, process sandboxing, and self-healing 
#' capabilities.
#' 
#' Arguments can be provided via:
#' 1. Direct arguments: `run(port = 8080)`
#' 2. Environment variables: `ATIMA_PORT=8080`
#' 3. R Options: `options(atima.port = 8080)`
#'
#' @param port        Integer. Port to listen on (default 8080).
#' @param host        String. IP address to listen on. The default,
#'                    "127.0.0.1", only accepts connections from this
#'                    computer. Use "0.0.0.0" to listen on all interfaces.
#' @param data_dir    String. Storage location for database and persistent files.
#' @param temp_dir    String. Storage location for temporary files.
#' @param workers     Integer. Maximum concurrent jobs.
#' @param max_cpus    Integer. Max CPU cores for a single job.
#' @param time_limit  Numeric. Max job runtime in seconds (default 3600).
#' @param cache_size_mb  Numeric. Max cache size in MB (default 100).
#' @param max_upload_mb  Numeric. Max upload size in MB (default 50).
#' @param smtp        List. SMTP settings (`server`, `port`, `username`, etc.) 
#'                    for emails.
#' @param open        Logical. Open browser on start?
#' 
#' @return This function blocks the R session until interrupted.
#' @export
run <- function(
    port          = 8080,
    host          = '127.0.0.1',
    data_dir      = tools::R_user_dir('atima', 'data'),
    temp_dir      = tempfile(pattern = 'atima_'),
    workers       = parallelly::availableCores(),
    max_cpus      = parallelly::availableCores(),
    time_limit    = 60,    # 1 minute    // 3600,  # 1 hour
    cache_size_mb = 100,   # 100 MB
    max_upload_mb = 50,    # 50 MB
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
  
  # Initialize DB (Internal function)
  db_init(config)
  
  job_registry <- new.env(parent = emptyenv())
  
  n_fast  <- 1
  n_heavy <- max(1, workers - 1)
  
  message(sprintf(" - Workers: %d Fast (Auth/DB) | %d Heavy (Compute)", n_fast, n_heavy))
  
  mirai::daemons(n = n_fast,  .compute = "fast_lane", dispatcher = FALSE)
  mirai::daemons(n = n_heavy, .compute = "heavy_lane")
  
  fast_paths <- paste0('/api/', c(
    'init_session', 'heartbeat', 'save', 'save_as',
    'change_metadata_class', 'account_details', 'abort',
    'jstree_select', 'jstree_rename', 'jstree_move', 
    'jstree_create', 'jstree_delete', 'jstree_leave', 
    'sharing_with', 'sharing_user_search',
    'update_permissions'
  ))
  
  
  #______________________________________________
  # 3. Request Launchers
  #
  
  fast_launcher <- function(req) {
    promises::then(
      promise = mirai::mirai(
        .expr    = atima:::simple_handler(req), 
        req      = req,
        .compute = "fast_lane"
      ),
      onFulfilled = function(res) {
        if (mirai::is_mirai_error(res)) {
          message("[!]  Fast Lane Worker Crash Detected - Restarting...")
          mirai::launch_local(n = 1, .compute = "fast_lane")
          return(response("System Service Restarted - Please Retry", 503L))
        }
        return(res)
      }
    )
  }
  
  heavy_launcher <- function(req) {
    
    session_key <- unname(req[['HEADERS']]['x-session-key'])
    if (!isTRUE(grepl("^[a-zA-Z0-9_]+$", session_key))) session_key <- NULL
    
    # 1. Cancel existing job
    if (!is.null(session_key) && exists(session_key, envir = job_registry)) {
      mirai::stop_mirai(job_registry[[session_key]])
    }
    
    # 2. Submit new job
    m <- mirai::mirai(
      .expr    = atima:::heavy_handler(req), 
      req      = req,
      .compute = "heavy_lane"
    )
    
    # 3. Register
    if (!is.null(session_key)) job_registry[[session_key]] <- m
    
    # 4. Handle Result
    promises::then(
      m,
      onFulfilled = function(res) {
        if (mirai::is_mirai_error(res)) {
          message("[!]  Heavy Lane Worker Crash Detected - Restarting...")
          mirai::launch_local(n = 1, .compute = "heavy_lane")
          return(response("Worker Process Crashed", 500L))
        }
        return(res)
      },
      onRejected = function(err) {
        return(response("Internal Server Error", 500L))
      }
    ) |> promises::finally(function() {
      if (!is.null(session_key) && exists(session_key, envir = job_registry)) {
        rm(list = session_key, envir = job_registry)
      }
    })
  }
  
  #______________________________________________
  # 4. HTTP Application Definition
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
        # error = function (e) { response(e$message, 500L) },
        expr  = {
          
          path <- req[['PATH_INFO']]
          
          # Matches '/', '/hmp50', and '/hmp50/', but NOT '/hmp50/biom.gz'
          if (length(strsplit(path, '/', fixed = TRUE)[[1]]) <= 2)
            return(static_index_html)
          
          if (is.function(req[['rook.input']]$read))
            req$RAW_ARGS <- req[['rook.input']]$read()
          
          req <- c(as.list(req), list(CONFIG = config))
          
          simple_handler(req)
          
          # if (path %in% fast_paths) { return(fast_launcher(req))  }
          # else                      { return(heavy_launcher(req)) }
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
  # 5. Start Server
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
#' Internal: Worker Process Handler
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
  
  # Internal functions need triple colon when running in worker
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


#______________________________________________________________________________
#' Internal: Sandbox Supervisor
#' @noRd
heavy_handler <- function(request) {
  
  p <- callr::r_bg(
    func    = atima:::simple_handler,
    args    = list(request = request),
    package = "atima"
  )
  
  end_time <- Sys.time() + request[['CONFIG']][['time_limit']]
  
  tryCatch({
    
    while (p$is_alive()) {
      p$wait(timeout = 500)
      
      if (Sys.time() > end_time) {
        p$kill()
        return(response("Job timed out (Server enforced)", 500L))
      }
    }
    return(p$get_result())
    
  }, interrupt = function(i) {
    p$kill()
    return(response("Superseded by new request", 409L))
    
  }, error = function(e) {
    p$kill()
    return(response(e$message, 500L))
  })
}
