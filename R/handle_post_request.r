#______________________________________________________________________________
#' Process /api requests. Always needs authenticated sessions.
#' @return list(headers, status, body)
handle_post_request <- function (REQ) {
  
  
  #________________________________________________________
  # Special case for first call to api backend.
  #________________________________________________________
  if (identical(REQ[['PATH']], '/api/init_session'))
    return (api_init_session(REQ))
  
  
  #________________________________________________________
  # Authenticate this session.
  #________________________________________________________
  resume_session(REQ)
  
  
  #________________________________________________________
  # Share cache with rbiom.
  #________________________________________________________
  rare_bf_id   <- REQ[['SESSION']][['rare_bf_id']]
  prev_options <- options()
  on.exit(options(prev_options), add = TRUE)
  options(
    rbiom.cache_dir  = file.path(REQ[['CONFIG']][['data_dir']], 'cache'), 
    rbiom.cache_size = REQ[['CONFIG']][['cache_size']],
    rbiom.cache_hash = function (args) {
      return (paste0(rare_bf_id, "_", hash(args)))
    })
  
  
  #________________________________________________________
  # Convert the URL's path to an atima::api_ function.
  #________________________________________________________
  api_fn <- local({
    
    x <- REQ[['PATH']]
    
    if (!is_scalar_character(x) || !startsWith(x, "/api/"))
      stop("Not an API path.")
    
    x <- strsplit(x, '/', fixed = TRUE)[[1]]
    if (length(x) < 3) stop("Not an API path.")
    x <- x[[3]]
    return (paste0("api_", x))
  })
  
  if (!exists(api_fn, where=asNamespace('atima'), mode='function'))
    stop("API function does not exist: ", api_fn)
  
  api_fun <- getFromNamespace(api_fn, ns='atima')
  params  <- formalArgs(api_fun)
  
  
  
  #________________________________________________________
  # Sanitize user-provided parameter names and arguments.
  #________________________________________________________
  ARGS     <- REQ[['ARGS']]
  api_args <- list(REQ = REQ)
  
  for (i in seq_along(ARGS)) {
    key <- names(ARGS)[[i]]
    
    if (!isTRUE(nchar(key) > 0))  stop("Parameter ", i, " is unnamed.")
    if (!key %in% params)         stop(key, " isn't needed by ", api_fn)
    if (!grepl("^[a-z_]+$", key)) stop("Parameter name isn't lowercase: ", key)
    if (hasName(api_args, key))   stop("Duplicate parameter name: ", key)
    
    if (endsWith(key, "_id"))
      if (!key %in% c("node_id", "parent_node_id"))
        ARGS[i] <- list(int(ARGS[[i]]))
    
    api_args[key] <- list(ARGS[[i]])
  }
  
  
  #________________________________________________________
  # Call the API function.
  #________________________________________________________
  result <- do.call(api_fun, api_args)
  
  
  return (result)
}
