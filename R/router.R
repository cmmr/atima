#______________________________________________________________________________
# The router.
#
# Every request that httpuv does not serve as a static file comes through
# `handle_request()`. It finds the request's entry in the route table
# (`R/routes.R`), loads the session, checks the permission the route asks
# for, validates the arguments against the route's declarations, and only
# then calls the handler. Handlers can therefore assume that their arguments
# have the declared types and that the caller is allowed to make the request.
# The permission rules themselves are in `R/access.R`.
#
# A handler for a `fast` route returns its response. A handler for a
# `compute` route may instead return a `job()` (see `R/jobs.R`): work for a
# worker process plus a `finish` function for its result. The handler and
# `finish` each run in their own database transaction, and no transaction is
# open while the job runs.
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
#' @param account     Must the caller be signed in? A guest is refused. (The
#'                    owner in `auth = "none"` mode counts as signed in.)
#' @param rule        The name of an entry of `access_rules` (`R/access.R`)
#'                    that checks the request's arguments, for routes whose
#'                    permission depends on what is being acted on.
#' @param modes       The authentication modes in which the route exists.
#' @param strict      Refuse arguments that are not declared? Only switched
#'                    off for pages that browsers are sent to from elsewhere:
#'                    the one an identity provider returns them to, since
#'                    providers add parameters of their own, and the app's
#'                    page, since links gather tracking parameters.
#' @param html        Is the route a page that people see? Its errors are
#'                    then sent as a small HTML page instead of JSON.
#' @param raw         Hand the handler the request as it came, as the two
#'                    arguments `body` (a raw vector) and `headers` (a named
#'                    character vector), instead of the arguments read from
#'                    it? For a route that speaks a protocol of its own
#'                    (`/mcp`), whose handler then parses the body and
#'                    reports what is wrong with it in that protocol's terms.
#' @param lane        `"fast"` for database-only work, `"compute"` for
#'                    anything that reads a BIOM file or calls rbiom. Only
#'                    a `compute` handler may return a `job()`.
#' @param supersede   For a `compute` route: does a new request from a
#'                    session replace that session's earlier request to
#'                    this route that is still queued or running? The
#'                    earlier request is answered with a 409. Use it where
#'                    only the latest answer matters, such as a plot.
#' @param args        A named list of argument declarations made with the
#'                    `arg_*()` functions. Path parameters are declared here
#'                    too. Arguments that are not declared are refused.
#' @return A list of class `route`.
#' @noRd
route <- function (
    endpoint, handler, permission, lane = "fast", args = list(), supersede = FALSE,
    account = FALSE, rule = NULL, modes = auth_modes, strict = TRUE, html = FALSE,
    raw = FALSE ) {

  parts <- strsplit(endpoint, " ", fixed = TRUE)[[1]]

  stopifnot(
    length(parts) == 2,
    parts[[1]] %in% c("GET", "POST"),
    startsWith(parts[[2]], "/"),
    is_scalar_character(handler),
    is_one_of(permission, permission_levels),
    is_one_of(lane, lanes),
    is_bool(supersede),
    !supersede || lane == "compute",
    is_bool(account),
    !account || permission != "public",
    is.null(rule) || is_one_of(rule, names(access_rules)),
    is.character(modes), length(modes) > 0, all(modes %in% auth_modes),
    is_bool(strict),
    is_bool(html),
    is_bool(raw),
    !raw || identical(names(args), c("body", "headers")),
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
    supersede   = supersede,
    account     = account,
    rule        = rule,
    modes       = modes,
    strict      = strict,
    html        = html,
    raw         = raw,
    args        = args ))
}


#______________________________________________________________________________
# Argument declarations.
#
# Each `arg_*()` returns an `arg_spec`: whether the argument may be left out,
# a default for when it is, and a `check` function that returns the cleaned
# value or stops with a short message.
#
# Most checks look at the value alone. One declared with `context = TRUE` is
# called as `check(value, REQ, args)`, where `args` are the arguments
# declared before it, already checked. That is for values whose meaning
# depends on another argument (the options of the plot function named in
# `plot_fn`) or on the open project (a metadata field).
#______________________________________________________________________________

arg_spec <- function (type, check, optional = FALSE, default = NULL, context = FALSE) {
  structure(class = "arg_spec", list(
    type = type, check = check, optional = isTRUE(optional) || !is.null(default), default = default,
    context = isTRUE(context) ))
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

#' A string that must not be logged or shown, such as a password. The
#' handler gets it wrapped (`secret()`); `reveal()` unwraps it. It is not
#' trimmed, and a refusal never quotes it.
#' @param min,max  Limits on the number of characters.
#' @noRd
arg_secret <- function (min = 1L, max = 1000L, ...) {
  arg_spec("secret", ..., check = function (x) {
    if (!is.character(x) || length(x) != 1 || is.na(x)) stop("must be a string")
    if (nchar(x) < min) stop("must be at least ", min, " characters")
    if (nchar(x) > max) stop("must be at most ", max, " characters")
    secret(x)
  })
}

#' One or more short strings, such as a list of ids. What the handler gets
#' is a character vector without duplicates.
#' @param pattern  A regular expression each value must match.
#' @param max_n    The most values to accept.
#' @noRd
arg_strings <- function (pattern, max_n = 1000L, ...) {
  arg_spec("strings", ..., check = function (x) {
    if (is.list(x) && all(vapply(x, function (v) is.character(v) && length(v) == 1, logical(1)))) x <- unlist(x)
    if (!is.character(x) || length(x) == 0 || anyNA(x)) stop("must be a list of strings")
    if (length(x) > max_n) stop("must have at most ", max_n, " values")
    if (!all(grepl(pattern, x, perl = TRUE))) stop("has a value with an invalid format")
    unique(x)
  })
}

#' A string of HTML that a user wrote, such as a project description. It is
#' reduced to harmless formatting (`sanitize_html()`), so what the handler
#' gets, and stores, is safe to put into a page.
#' @param max  Limit on the number of characters, before and after cleaning.
#' @noRd
arg_html <- function (max = 10000L, ...) {
  arg_spec("html", ..., check = function (x) {
    if (!is.character(x) || length(x) != 1 || is.na(x)) stop("must be a string")
    if (nchar(x) > max) stop("must be at most ", max, " characters")
    x <- sanitize_html(x)
    if (nchar(x) > max) stop("must be at most ", max, " characters")
    x
  })
}

#' The body of a request, untouched, for a `raw` route.
#' @param max  The most bytes to accept.
#' @noRd
arg_body <- function (max = 1048576L, ...) {
  arg_spec("body", ..., check = function (x) {
    if (!is.raw(x)) stop("must be the request's body")
    if (length(x) > max) stop("must be at most ", max, " bytes")
    x
  })
}

#' The headers of a request, for a `raw` route: a character vector named by
#' header, in lower case.
#' @noRd
arg_headers <- function (...) {
  arg_spec("headers", ..., check = function (x) {
    if (!is.character(x) || (length(x) > 0 && is.null(names(x)))) stop("must be the request's headers")
    names(x) <- tolower(names(x))
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

#' Structured JSON (an object or array) whose contents the handler is
#' responsible for. Only for what DataTables sends with a page request.
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

#' The summary of the project open in the request's session, if the main
#' process has it in memory. It does after any request that showed the
#' project, so in practice always, except just after a restart.
#' @noRd
known_summary <- function (REQ) {
  if (is.null(REQ) || is.null(REQ[['SESSION']][['full_bf_id']])) return (NULL)
  memo_get(REQ)
}

#' The arguments for an rbiom function, checked against the schema
#' (`R/schema.R`): only parameters a remote caller may set, each with a
#' valid value for the open project. What the handler gets is the arguments
#' as rbiom reads them.
#'
#' If the project's summary is not in memory, only the checks that need no
#' data are made here, and the handler has the worker make the rest before
#' it does anything else (`worker_check()`).
#'
#' @param fn_arg  The name of the argument that names the function. It must
#'                be declared before this one.
#' @noRd
arg_fn_args <- function (fn_arg, ...) {
  arg_spec("fn_args", context = TRUE, ..., check = function (x, REQ = NULL, args = list()) {
    fn <- args[[fn_arg]]
    if (!is_one_of(fn, names(schema_functions))) stop("cannot be checked without a valid '", fn_arg, "'")
    summary <- known_summary(REQ)
    if (is.null(summary)) return (check_fn_args_static(fn, x))
    check_fn_args(fn, x, summary)
  })
}

#' The image settings of a plot request; see `check_save_args()`.
#' @noRd
arg_save_args <- function (...) {
  arg_spec("save_args", ..., check = function (x) check_save_args(x))
}

#' The sample filter of a plot request; see `check_subset_args()`.
#' @noRd
arg_subset_args <- function (...) {
  arg_spec("subset_args", context = TRUE, ..., check = function (x, REQ = NULL, args = list()) {
    check_subset_args(x, known_summary(REQ))
  })
}

#' A taxonomic rank of the open project. `"otu"` is accepted for `".otu"`.
#' @noRd
arg_rank <- function (...) {
  arg_spec("rank", context = TRUE, ..., check = function (x, REQ = NULL, args = list()) {
    if (!is.character(x) || length(x) != 1 || is.na(x) || !nzchar(x) || nchar(x) > 100) stop("must be the name of a rank")
    if (tolower(x) == "otu") x <- ".otu"
    summary <- known_summary(REQ)
    if (!is.null(summary) && !x %in% as.character(unlist(summary[['ranks']])))
      stop("is not a rank of this project")
    x
  })
}

#' A diversity metric that rbiom knows, by its id. One that needs a
#' phylogenetic tree is refused if the open project has none.
#' @param fn,param  The rbiom function and parameter whose choices to use.
#' @noRd
arg_metric <- function (fn, param, ...) {
  arg_spec("metric", context = TRUE, ..., check = function (x, REQ = NULL, args = list()) {
    metrics <- Filter(function (p) p[['name']] == param, rbiom_schema()[[fn]][['params']])[[1]][['choices']]
    ids     <- vapply(metrics, function (m) m[['id']], character(1))
    if (!is_one_of(x, ids)) stop("is not one of the allowed values")
    summary <- known_summary(REQ)
    if (!is.null(summary) && !isTRUE(as.logical(summary[['tree']])) && isTRUE(metrics[[match(x, ids)]][['phylo']]))
      stop("needs a phylogenetic tree, which this project does not have")
    x
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
#' @param mode  The authentication mode the server runs in. Routes that do
#'              not exist in that mode are skipped.
#' @return `list(route, params)`. Stops with a 404, or a 405 if the path
#'         exists under another method.
#' @noRd
match_route <- function (method, path, routes = route_table(), mode = NULL) {

  if (!is_scalar_character(path)) stop_not_found("Not found.")

  segments <- strsplit(path, "/", fixed = TRUE)[[1]]
  segments <- segments[nzchar(segments)]

  other_method <- FALSE

  for (r in routes) {

    if (length(r[['segments']]) != length(segments)) next
    if (!is.null(mode) && !(mode %in% r[['modes']]))   next

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
#' @param REQ    The request environment, for the checks that depend on the
#'               open project.
#' @return The cleaned arguments, with defaults filled in, in declaration
#'         order. Stops with a 400 that names the offending argument.
#' @noRd
validate_args <- function (route, args, REQ = NULL) {

  specs <- route[['args']]

  if (length(args) > 0) {

    keys <- names(args)

    if (is.null(keys) || any(is.na(keys)) || !all(nzchar(keys)))
      stop_user("Arguments must be named.")

    if (anyDuplicated(keys))
      stop_user("Argument '", keys[[anyDuplicated(keys)]], "' was given twice.")

    unknown <- setdiff(keys, names(specs))
    if (length(unknown) > 0 && route[['strict']])
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
      expr  = if (spec[['context']]) spec[['check']](value, REQ, clean) else spec[['check']](value),
      error = function (e) stop_arg(key, e) ))
  }

  return (clean)
}


#' Stop with the 400 that reports a bad argument.
#' @param key  The argument's name.
#' @param e    The error its check raised.
#' @noRd
stop_arg <- function (key, e) {
  if (inherits(e, "atima_http_error")) stop(e)
  stop_user("Argument '", key, "' ", conditionMessage(e), ".")
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

  if (route[['account']] && !isFALSE(session[['is_guest']]))
    stop_forbidden("Please sign in to do this.")

  invisible(TRUE)
}


#______________________________________________________________________________
#' Apply the rule a route names, if any, to the validated arguments.
#' @noRd
check_rule <- function (REQ, route, args) {
  rule <- route[['rule']]
  if (!is.null(rule)) access_rules[[rule]](REQ, args)
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
#' @param app      `list(db, config, pool, memo)`: the open database
#'                 connection, the server configuration, the worker pool and
#'                 the in-memory project summaries. Without a pool, jobs run
#'                 in this process, which is how most tests run.
#' @return A `response()`, or, when the handler returned a job and there is
#'         a pool, a promise of one. Never stops and never rejects: every
#'         error becomes a response with a short message and an error id.
#' @noRd
handle_request <- function (request, app) {

  started <- Sys.time()

  REQ <- as.environment(list(
    DB      = app[['db']],
    CONFIG  = app[['config']],
    POOL    = app[['pool']],
    MEMO    = app[['memo']],
    LEGACY  = app[['legacy']],
    AUTH    = app[['auth']],
    METHOD  = request[['REQUEST_METHOD']],
    PATH    = request[['PATH_INFO']],
    CLIENT  = request_client(request, app[['config']]),
    SESSION = list() ))


  #________________________________________________________
  # Route, session, permission, arguments, rule, handler.
  #________________________________________________________
  out <- request_stage(REQ, {

    check_host(REQ, request)
    check_origin(REQ, request)

    matched <- match_route(REQ[['METHOD']], REQ[['PATH']], mode = REQ[['CONFIG']][['auth']])
    route   <- matched[['route']]

    REQ[['ROUTE']] <- route

    if (route[['permission']] != "public")
      resume_session(REQ)

    check_permission(REQ, route)

    args <- if (route[['raw']]) request_raw(request) else request_args(request)
    args <- validate_args(route, c(args, matched[['params']]), REQ)

    check_rule(REQ, route, args)

    # Nothing a handler writes is kept unless the handler finishes.
    out <- db_transaction(REQ[['DB']], call_handler(route, REQ, args))

    if (inherits(out, "job") && !inherits(out, "waiting") && route[['lane']] != "compute")
      stop("The handler of a fast route returned a job: ", route[['endpoint']])

    out
  })

  if (!inherits(out, "job"))
    return (request_done(REQ, started, out))


  #________________________________________________________
  # The handler left work for a worker. When that is done,
  # `finish` turns the result into the response.
  #________________________________________________________
  session <- REQ[['SESSION']]

  finish <- function (outcome) interruptible(finish_now(outcome), stopping_response())

  finish_now <- function (outcome) {

    timing <- NULL

    resp <- request_done(REQ, started, request_stage(REQ, {

      # A job that says what to answer when it fails gets to say it; any
      # other failure is this request's error.
      result <- tryCatch(
        expr  = {
          done   <- outcome()
          timing <- done[['timing']]
          list(value = job_value(done))
        },
        error = function (e) {
          if (is.null(out[['failed']])) stop(e)
          list(failed = out[['failed']](e))
        })

      if (!is.null(result[['failed']])) {
        result[['failed']]

      } else {

        db_transaction(REQ[['DB']], {

          # Other requests ran in the meantime. Reload the session, and give
          # up if it has moved on to a different project.
          if (!is.null(session[['session_key']])) {
            resume_session(REQ, session[['auth_token']], session[['session_key']])
            if (!identical(REQ[['SESSION']][['draft_id']], session[['draft_id']]))
              stop_http(409L, "The open project changed while this was running.")
          }

          resp <- out[['finish']](result[['value']])

          if (inherits(resp, "job"))
            stop("The finish step of a job returned another job: ", out[['fn']])

          resp
        })
      }
    }))

    server_timing(resp, timing)
  }

  # The handler waits for something that needs no worker.
  if (inherits(out, "waiting")) {

    waited <- tryCatch(out[['start']](), error = function (e) promises::promise_reject(e))

    return (promises::then(
      promise     = waited,
      onFulfilled = function (value) finish(function () list(value = value)),
      onRejected  = function (error) finish(function () stop(error)) ))
  }

  pool <- REQ[['POOL']]

  if (is.null(pool))
    return (finish(function () run_inline(out[['fn']], out[['args']])))

  key <- NULL
  if (isTRUE(REQ[['ROUTE']][['supersede']]) && !is.null(session[['session_id']]))
    key <- paste(session[['session_id']], REQ[['ROUTE']][['path']])

  promises::then(
    promise     = pool_submit(pool, out[['fn']], out[['args']], session[['session_id']], key, user_id = session[['user_id']]),
    onFulfilled = function (value) finish(function () value),
    onRejected  = function (error) finish(function () stop(error)) )
}


#______________________________________________________________________________
#' Say in a response how long its job waited for a worker and how long it
#' ran, as a `Server-Timing` header (`queue;dur=<ms>, job;dur=<ms>`).
#' Browsers show it in their developer tools, and the load test reads it.
#' It says nothing about the request's content.
#' @noRd
server_timing <- function (resp, timing) {

  if (is.numeric(timing) && all(c("queue", "job") %in% names(timing)))
    resp[['headers']][['Server-Timing']] <- sprintf(
      "queue;dur=%.1f, job;dur=%.1f", timing[['queue']], timing[['job']])

  resp
}


#______________________________________________________________________________
#' Run one stage of a request. An error becomes the error response, with the
#' details logged.
#' @return The value of `code`, or a `response()` describing the error.
#' @noRd
request_stage <- function (REQ, code) {

  calls <- NULL

  tryCatch(
    error = function (e) error_response(e, REQ, calls),
    expr  = withCallingHandlers(
      error = function (e) if (is.null(calls)) calls <<- sys.calls(),
      expr  = code ))
}


#______________________________________________________________________________
#' Make sure a request's result is a `response()`, and log the request.
#' @noRd
request_done <- function (REQ, started, resp) {

  if (!inherits(resp, "response"))
    resp <- tryCatch(response(resp), error = function (e) error_response(e, REQ))

  log_event(
    level   = "info",
    event   = "request",
    method  = REQ[['METHOD']],
    path    = REQ[['ROUTE']][['path']] %||% "(no route)",
    rpc     = REQ[['RPC']],
    status  = resp[['status']],
    ms      = round(as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000),
    user_id = REQ[['SESSION']][['user_id']] )

  return (resp)
}


#______________________________________________________________________________
#' The credentials a request carries: auth cookie, session key and address,
#' and whether it came over HTTPS.
#' @noRd
request_client <- function (request, config = list()) {

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

  oidc_login <- cookies[['oidc_login']]
  if (!isTRUE(grepl("^[a-zA-Z0-9]{43}$", oidc_login)))    oidc_login  <- NULL

  list(
    auth_token  = auth_token,
    session_key = session_key,
    oidc_login  = oidc_login,
    https       = request_is_https(request, config),
    ip_address  = request[['REMOTE_ADDR']] %||% "" )
}


#______________________________________________________________________________
#' A request as it came, for a `raw` route: its body and its headers.
#' @return `list(body = <raw>, headers = <named character>)`
#' @noRd
request_raw <- function (request) {

  body  <- NULL
  input <- request[['rook.input']]
  if (identical(request[['REQUEST_METHOD']], "POST") && !is.null(input) && is.function(input$read))
    body <- input$read()

  list(body = body %||% raw(0), headers = request[['HEADERS']] %||% character(0))
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

  # In a query string, "key=" and a bare "key" are an empty value.
  if (isTRUE(nzchar(request[['QUERY_STRING']])))
    args <- c(args, tryCatch(
      expr  = lapply(as.list(parse_query(request[['QUERY_STRING']])), function (value) {
        if (length(value) == 1 && is.na(value)) "" else value }),
      error = function (e) stop_user("The query string could not be read.") ))

  return (args)
}
