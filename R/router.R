#______________________________________________________________________________
# The router.
#
# Every request that httpuv does not serve as a static file comes through
# `handle_request()`. It finds the request's entry in the route table
# (`R/routes.R`), loads the session, checks the permission the route asks
# for, validates the arguments against the route's declarations, and only
# then calls the handler. Handlers can therefore assume that their arguments
# have the declared types and that the session has the declared permission.
#______________________________________________________________________________


permission_levels <- c("public", "session", "viewer", "editor", "admin")
lanes             <- c("fast", "compute")


#______________________________________________________________________________
#' Declare one route.
#'
#' @param endpoint    Method and path, e.g. `"POST /api/project/save"`. A
#'                    path segment that starts with `:` matches anything and
#'                    is passed to the handler as an argument of that name.
#' @param handler     The name of the function to call. It is called as
#'                    `handler(REQ, <arguments>)`.
#' @param permission  What the caller needs:
#'   \describe{
#'     \item{`public`}{nothing; there may be no session at all.}
#'     \item{`session`}{a valid session.}
#'     \item{`viewer`}{a session that can read its open project.}
#'     \item{`editor`}{a session that can change its open project.}
#'     \item{`admin`}{a session whose user is an administrator.}
#'   }
#' @param lane        `"fast"` for database-only work, `"compute"` for
#'                    anything that reads a BIOM file or calls rbiom.
#' @param args        A named list of argument declarations made with the
#'                    `arg_*()` functions. Path parameters are declared here
#'                    too. Arguments that are not declared are refused.
#' @return A list of class `route`.
#' @noRd
route <- function (endpoint, handler, permission, lane = "fast", args = list()) {

  parts <- strsplit(endpoint, " ", fixed = TRUE)[[1]]

  stopifnot(
    length(parts) == 2,
    parts[[1]] %in% c("GET", "POST"),
    startsWith(parts[[2]], "/"),
    is_scalar_character(handler),
    is_one_of(permission, permission_levels),
    is_one_of(lane, lanes),
    is.list(args),
    length(args) == 0 || (!is.null(names(args)) && all(grepl("^[a-z_]+$", names(args)))),
    all(vapply(args, inherits, logical(1), "arg_spec")) )

  segments <- strsplit(parts[[2]], "/", fixed = TRUE)[[1]]
  segments <- segments[nzchar(segments)]

  structure(class = "route", list(
    endpoint    = endpoint,
    method      = parts[[1]],
    path        = parts[[2]],
    segments    = segments,
    path_params = sub("^:", "", segments[startsWith(segments, ":")]),
    handler     = handler,
    permission  = permission,
    lane        = lane,
    args        = args ))
}


#______________________________________________________________________________
# Argument declarations.
#
# Each `arg_*()` returns an `arg_spec`: whether the argument may be left out,
# a default for when it is, and a `check` function that returns the cleaned
# value or stops with a short message.
#______________________________________________________________________________

arg_spec <- function (type, check, optional = FALSE, default = NULL) {
  structure(class = "arg_spec", list(
    type = type, check = check, optional = isTRUE(optional) || !is.null(default), default = default ))
}

#' A single string.
#' @param min,max  Limits on the number of characters, after trimming.
#' @param pattern  A regular expression the whole value must match.
#' @param trim     Remove leading and trailing whitespace.
#' @noRd
arg_string <- function (min = 0L, max = 10000L, pattern = NULL, trim = TRUE, ...) {
  arg_spec("string", ..., check = function (x) {
    if (!is.character(x) || length(x) != 1 || is.na(x)) stop("must be a string")
    if (trim) x <- trimws(x)
    if (nchar(x) < min) stop("must be at least ", min, " characters")
    if (nchar(x) > max) stop("must be at most ", max, " characters")
    if (!is.null(pattern) && !grepl(pattern, x, perl = TRUE)) stop("has an invalid format")
    x
  })
}

#' A whole number. Strings of digits are accepted, as form fields and query
#' strings have no number type.
#' @noRd
arg_int <- function (min = -.Machine$integer.max, max = .Machine$integer.max, ...) {
  arg_spec("int", ..., check = function (x) {
    if (is.character(x) && length(x) == 1 && grepl("^-?[0-9]{1,10}$", x)) x <- as.numeric(x)
    if (!is.numeric(x) || length(x) != 1 || is.na(x) || x %% 1 != 0) stop("must be a whole number")
    if (x < min) stop("must be at least ", min)
    if (x > max) stop("must be at most ", max)
    as.integer(x)
  })
}

#' `true` or `false`.
#' @noRd
arg_bool <- function (...) {
  arg_spec("bool", ..., check = function (x) {
    if (is.character(x) && length(x) == 1 && x %in% c("true", "false")) x <- (x == "true")
    if (!is.logical(x) || length(x) != 1 || is.na(x)) stop("must be true or false")
    x
  })
}

#' One string from a fixed list.
#' @noRd
arg_choice <- function (choices, ...) {
  stopifnot(is.character(choices), length(choices) > 0)
  arg_spec("choice", ..., check = function (x) {
    if (!is_one_of(x, choices)) stop("is not one of the allowed values")
    x
  })
}

#' Structured JSON (an object or array) whose contents the handler, or a
#' later schema, is responsible for.
#' @noRd
arg_json <- function (...) {
  arg_spec("json", ..., check = function (x) {
    if (!is.list(x) && !is.atomic(x)) stop("must be JSON data")
    x
  })
}

#' An uploaded file from a multipart form: `list(filename, value)` where
#' `value` is a raw vector.
#' @noRd
arg_file <- function (...) {
  arg_spec("file", ..., check = function (x) {
    if (!is.list(x) || !is.raw(x[['value']]) || !is_scalar_character(x[['filename']]))
      stop("must be an uploaded file")
    if (length(x[['value']]) == 0) stop("is an empty file")
    x[c('filename', 'value')]
  })
}

#' A node of the project tree: a letter from `kinds` followed by an id, e.g.
#' `"C12"`. `C` is a collection, `P` one of the user's own projects (the id
#' is a permission id), `G` a public project (the id is a project id).
#' @param root  Also accept `"#"`, the top of the tree.
#' @noRd
arg_node <- function (kinds = "CPG", root = FALSE, ...) {
  pattern <- sprintf("^[%s][0-9]{1,9}$", kinds)
  arg_spec("node", ..., check = function (x) {
    if (!is.character(x) || length(x) != 1 || is.na(x)) stop("must be a string")
    if (root && identical(x, "#")) return (x)
    if (!grepl(pattern, x)) stop("is not a valid tree node")
    x
  })
}


#______________________________________________________________________________
#' Find the route for a request.
#'
#' Routes are tried in table order, so a literal path must be listed before
#' a parameterised one that would also match it.
#'
#' @return `list(route, params)`. Stops with a 404, or a 405 if the path
#'         exists under another method.
#' @noRd
match_route <- function (method, path, routes = route_table()) {

  if (!is_scalar_character(path)) stop_not_found("Not found.")

  segments <- strsplit(path, "/", fixed = TRUE)[[1]]
  segments <- segments[nzchar(segments)]

  other_method <- FALSE

  for (r in routes) {

    if (length(r[['segments']]) != length(segments)) next

    is_param <- startsWith(r[['segments']], ":")
    if (!all(is_param | r[['segments']] == segments)) next

    # Only a path that names a route exactly counts as "wrong method".
    if (!identical(r[['method']], method)) {
      if (!any(is_param)) other_method <- TRUE
      next
    }

    params <- as.list(segments[is_param])
    names(params) <- r[['path_params']]

    return (list(route = r, params = params))
  }

  if (other_method) stop_http(405L, "Method not allowed.")
  stop_not_found("Not found.")
}


#______________________________________________________________________________
#' Check a request's arguments against a route's declarations.
#'
#' @param route  A `route`.
#' @param args   The named list of arguments that came with the request.
#' @return The cleaned arguments, with defaults filled in, in declaration
#'         order. Stops with a 400 that names the offending argument.
#' @noRd
validate_args <- function (route, args) {

  specs <- route[['args']]

  if (length(args) > 0) {

    keys <- names(args)

    if (is.null(keys) || any(is.na(keys)) || !all(nzchar(keys)))
      stop_user("Arguments must be named.")

    if (anyDuplicated(keys))
      stop_user("Argument '", keys[[anyDuplicated(keys)]], "' was given twice.")

    unknown <- setdiff(keys, names(specs))
    if (length(unknown) > 0)
      stop_user("Unknown argument '", log_truncate(unknown[[1]], 40L), "'.")
  }

  clean <- list()

  for (key in names(specs)) {

    spec  <- specs[[key]]
    value <- args[[key]]

    if (is.null(value)) {
      if (!spec[['optional']])           stop_user("Missing argument '", key, "'.")
      if (!is.null(spec[['default']]))   clean[[key]] <- spec[['default']]
      next
    }

    clean[key] <- list(tryCatch(
      expr  = spec[['check']](value),
      error = function (e) stop_user("Argument '", key, "' ", conditionMessage(e), ".") ))
  }

  return (clean)
}


#______________________________________________________________________________
#' Stop unless the session has the permission a route asks for.
#'
#' @param REQ    The request environment. For anything but a `public` route
#'               its session has already been loaded.
#' @param route  A `route`.
#' @noRd
check_permission <- function (REQ, route) {

  level   <- route[['permission']]
  session <- REQ[['SESSION']]

  if (level == "public") return (invisible(TRUE))

  if (is.null(session[['session_id']]))
    stop_unauthorized("This session has expired. Please reload the page.")

  access <- session[['access']]

  ok <- switch(
    EXPR    = level,
    session = TRUE,
    viewer  = is_one_of(access, c("viewer", "editor")),
    editor  = identical(access, "editor"),
    admin   = isTRUE(session[['is_admin']]),
    FALSE )

  if (!ok)
    stop_forbidden(switch(
      EXPR   = level,
      viewer = "You do not have access to this project.",
      editor = "You do not have permission to change this project.",
      admin  = "This action needs an administrator.",
      "Not allowed." ))

  invisible(TRUE)
}


#______________________________________________________________________________
#' Call a route's handler. A separate function so that tests can replace it.
#' @noRd
call_handler <- function (route, REQ, args) {
  handler <- get(route[['handler']], envir = asNamespace("atima"), mode = "function")
  do.call(handler, c(list(REQ = REQ), args))
}


#______________________________________________________________________________
#' Handle one HTTP request.
#'
#' @param request  The request environment from httpuv.
#' @param app      `list(db, config)`: the open database connection and the
#'                 server configuration.
#' @return A `response()`. Never stops: every error becomes a response with
#'         a short message and an error id.
#' @noRd
handle_request <- function (request, app) {

  started <- Sys.time()
  calls   <- NULL

  REQ <- as.environment(list(
    DB      = app[['db']],
    CONFIG  = app[['config']],
    METHOD  = request[['REQUEST_METHOD']],
    PATH    = request[['PATH_INFO']],
    URL     = paste0("http://", request[['HTTP_HOST']]),
    CLIENT  = request_client(request),
    SESSION = list() ))

  resp <- tryCatch(

    error = function (e) error_response(e, REQ, calls),

    expr = withCallingHandlers(

      error = function (e) if (is.null(calls)) calls <<- sys.calls(),

      expr = {

        matched <- match_route(REQ[['METHOD']], REQ[['PATH']])
        route   <- matched[['route']]

        REQ[['ROUTE']] <- route

        if (route[['permission']] != "public")
          resume_session(REQ)

        check_permission(REQ, route)

        args <- c(request_args(request), matched[['params']])
        args <- validate_args(route, args)

        # Nothing a handler writes is kept unless the handler finishes.
        resp <- db_transaction(REQ[['DB']], with_rbiom_cache(REQ, call_handler(route, REQ, args)))

        if (inherits(resp, "response")) resp else response(resp)
      }))

  log_event(
    level   = "info",
    event   = "request",
    method  = REQ[['METHOD']],
    path    = REQ[['ROUTE']][['path']] %||% "(no route)",
    status  = resp[['status']],
    ms      = round(as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000),
    user_id = REQ[['SESSION']][['user_id']] )

  return (resp)
}


#______________________________________________________________________________
#' The credentials a request carries: auth cookie, session key and address.
#' @noRd
request_client <- function (request) {

  cookies <- list()
  if (isTRUE(nzchar(request[['HTTP_COOKIE']]))) {
    for (cookie in strsplit(request[['HTTP_COOKIE']], ";", fixed = TRUE)[[1]]) {
      parts <- trimws(strsplit(cookie, "=", fixed = TRUE)[[1]])
      if (length(parts) >= 2)
        cookies[[parts[[1]]]] <- paste(parts[-1], collapse = "=")
    }
  }

  auth_token  <- cookies[['auth_token']]
  session_key <- unname(request[['HEADERS']]['x-session-key'])

  if (!isTRUE(grepl("^[a-zA-Z0-9]{64}$", auth_token)))    auth_token  <- NULL
  if (!isTRUE(grepl("^[a-zA-Z0-9]{1,40}$", session_key))) session_key <- NULL

  list(
    auth_token  = auth_token,
    session_key = session_key,
    ip_address  = request[['REMOTE_ADDR']] %||% "" )
}


#______________________________________________________________________________
#' The arguments a request carries in its body and query string.
#'
#' Bodies may be JSON (an object), a URL-encoded form or a multipart form.
#' In a multipart form, plain fields are converted from raw to strings and
#' file fields are left as `list(filename, value)`.
#'
#' @return A named list. Stops with a 400 if the body cannot be parsed.
#' @noRd
request_args <- function (request) {

  args <- list()

  body  <- NULL
  input <- request[['rook.input']]
  if (identical(request[['REQUEST_METHOD']], "POST") && !is.null(input) && is.function(input$read))
    body <- input$read()

  if (length(body) > 0) {

    content_type <- request[['CONTENT_TYPE']] %||% ""

    args <- tryCatch(
      expr  = parse_http(body, content_type),
      error = function (e) stop_user("The request body could not be read.") )

    if (grepl("multipart/form-data", content_type, fixed = TRUE))
      args <- lapply(args, function (field) {
        if (is.list(field) && is.raw(field[['value']]) && is.null(field[['filename']]))
          return (rawToChar(field[['value']]))
        field
      })

    if (!is.list(args) || (length(args) > 0 && is.null(names(args))))
      stop_user("The request body must be a set of named arguments.")
  }

  if (isTRUE(nzchar(request[['QUERY_STRING']])))
    args <- c(args, tryCatch(
      expr  = as.list(parse_query(request[['QUERY_STRING']])),
      error = function (e) stop_user("The query string could not be read.") ))

  return (args)
}


#______________________________________________________________________________
#' Point rbiom's cache at atima's cache directory while `code` runs, with
#' keys tied to the session's rarefied BIOM file.
#' @noRd
with_rbiom_cache <- function (REQ, code) {

  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  if (is.null(rare_bf_id)) return (force(code))

  prev <- options(
    rbiom.cache_dir  = file.path(REQ[['CONFIG']][['data_dir']], 'cache'),
    rbiom.cache_size = REQ[['CONFIG']][['cache_size']],
    rbiom.cache_hash = function (args) paste0(rare_bf_id, "_", hash(args)) )
  on.exit(options(prev), add = TRUE)

  force(code)
}
