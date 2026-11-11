# The router: the route table itself, argument validation and permission
# enforcement, for every route.


# Arguments that pass validation, for each route that needs any.
valid_args <- list(
  "POST /api/project/upload"           = list(biom_file = list(filename = "study.biom", value = as.raw(1:10))),
  "POST /api/project/upload_component" = list(component = "metadata", component_file = list(filename = "md.csv", value = as.raw(1:10))),
  "POST /api/project/rarefy"           = list(depth = 1000),
  "POST /api/project/save"             = list(title = "My study", description = "<p>About</p>"),
  "POST /api/project/save_as"          = list(title = "My study", description = "<p>About</p>"),
  "POST /api/project/publish"          = list(is_public = TRUE),
  "POST /api/project/export"           = list(what = "metadata"),
  "POST /api/tree/select"              = list(node_id = "P1"),
  "POST /api/tree/create"              = list(node_id = "#"),
  "POST /api/tree/rename"              = list(node_id = "C1", text = "New name"),
  "POST /api/tree/leave"               = list(node_id = "P1"),
  "POST /api/tree/delete"              = list(node_id = "C1"),
  "POST /api/tree/move"                = list(node_id = "P1", parent_node_id = "C1"),
  "POST /api/sharing/user_search"      = list(query = "ada"),
  "POST /api/sharing/update"           = list(user_id = 5, permissions = "view"),
  "POST /api/metadata/change_class"    = list(col_num = 2),
  "POST /api/metadata/levels"          = list(field = "Body Site"),
  "POST /api/metadata/minmax"          = list(field = "Age"),
  "POST /api/plot"                     = list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1000),
  "GET /unsaved/:session_key/:file"    = list(session_key = "12abcDEF", file = "rare.json"),
  "GET /:access_key/:file"             = list(access_key = "hmp50", file = "full.tab.gz"),
  "GET /:access_key"                   = list(access_key = "hmp50") )

required_args <- function (route) {
  names(route$args)[!vapply(route$args, function (spec) spec$optional, logical(1))]
}

# A request for `route` carrying `args`, sent as JSON, or as a multipart
# form if any argument is a file. Path parameters go into the path.
route_request <- function (route, args = list(), session = NULL) {

  path <- route$path
  for (param in route$path_params) {
    path <- sub(paste0(":", param), args[[param]], path, fixed = TRUE)
    args[[param]] <- NULL
  }

  if (route$method == "GET")
    return (fake_request("GET", path, session = session))

  if (any(vapply(args, function (a) is.list(a) && is.raw(a$value), logical(1)))) {
    args <- lapply(args, function (a) if (is.list(a)) a else as.character(a))
    form <- multipart_body(args)
    return (fake_request("POST", path, form$body, session, content_type = form$content_type))
  }

  fake_request("POST", path, args, session)
}


# The route table -------------------------------------------------------------

test_that("every route is well formed and has a handler that takes its arguments", {

  routes <- route_table()

  endpoints <- vapply(routes, function (r) r$endpoint, character(1))
  expect_identical(anyDuplicated(endpoints), 0L)

  for (r in routes) {

    expect_s3_class(r, "route")
    expect_true(r$permission %in% c("public", "session", "viewer", "editor", "admin"), info = r$endpoint)
    expect_true(all(r$modes %in% c("none", "oidc")), info = r$endpoint)
    if (!is.null(r$rule)) expect_true(r$rule %in% names(access_rules), info = r$endpoint)

    # A route that acts on a tree node, or changes a grant, or is opened
    # with a key, has a rule that checks it.
    types <- vapply(r$args, function (spec) spec$type, character(1))
    if ("node" %in% types)              expect_true(r$rule %in% c("tree", "tree_edit"), info = r$endpoint)
    if (startsWith(r$path, "/unsaved")) expect_identical(r$rule, "draft_key")
    if (r$path == "/:access_key/:file") expect_identical(r$rule, "project_key")
    if (r$handler == "api_update_permissions") expect_identical(r$rule, "grant")
    expect_true(r$lane %in% c("fast", "compute"), info = r$endpoint)
    expect_true(r$method %in% c("GET", "POST"), info = r$endpoint)

    expect_true(exists(r$handler, envir = asNamespace("atima"), mode = "function"), info = r$endpoint)
    params <- formals(get(r$handler, envir = asNamespace("atima")))

    # The handler takes REQ plus exactly the declared arguments.
    expect_identical(names(params)[[1]], "REQ", info = r$endpoint)
    expect_setequal(names(params)[-1], as.character(names(r$args)))

    # An argument the handler needs is one the router insists on (or fills in).
    for (key in names(r$args)) {
      has_default <- !identical(params[[key]], quote(expr = ))
      spec        <- r$args[[key]]
      if (!has_default)
        expect_true(!spec$optional || !is.null(spec$default), info = paste(r$endpoint, key))
    }

    # Path parameters are declared like any other argument.
    expect_true(all(r$path_params %in% names(r$args)), info = r$endpoint)
  }
})


test_that("every api_ function is reachable through exactly one route", {

  ns        <- asNamespace("atima")
  api_funs  <- grep("^api_", ls(ns), value = TRUE)
  api_funs  <- api_funs[vapply(api_funs, function (f) is.function(get(f, envir = ns)), logical(1))]
  handlers  <- vapply(route_table(), function (r) r$handler, character(1))
  api_routes <- handlers[startsWith(handlers, "api_")]

  expect_setequal(api_routes, api_funs)
  expect_identical(anyDuplicated(api_routes), 0L)

  # API routes are POSTs under /api/; nothing else is.
  for (r in route_table()) {
    is_api <- startsWith(r$handler, "api_")
    expect_identical(startsWith(r$path, "/api/"), is_api, info = r$endpoint)
    if (is_api) expect_identical(r$method, "POST", info = r$endpoint)
  }
})


test_that("the test's valid arguments cover every route", {

  for (r in route_table()) {

    args <- valid_args[[r$endpoint]] %||% list()
    expect_true(all(required_args(r) %in% names(args)), info = r$endpoint)

    # Path parameters are strings by the time they are validated.
    for (param in r$path_params) args[[param]] <- as.character(args[[param]])
    expect_no_error(validate_args(r, args))
  }

  expect_true(all(names(valid_args) %in% vapply(route_table(), function (r) r$endpoint, character(1))))
})


test_that("route() refuses malformed declarations", {

  expect_error(route("DELETE /api/x", "api_heartbeat", "session"))
  expect_error(route("POST api/x",    "api_heartbeat", "session"))
  expect_error(route("POST /api/x",   "api_heartbeat", "owner"))
  expect_error(route("POST /api/x",   "api_heartbeat", "session", "slow"))
  expect_error(route("POST /api/x",   api_heartbeat,   "session"))
  expect_error(route("POST /api/x",   "api_heartbeat", "session", args = list("string")))
  expect_error(route("POST /api/x",   "api_heartbeat", "session", args = list(User = arg_string())))
})


# Matching --------------------------------------------------------------------

test_that("match_route finds routes and path parameters", {

  m <- match_route("POST", "/api/project/save")
  expect_identical(m$route$handler, "api_save")
  expect_identical(m$params, structure(list(), names = character(0)))

  m <- match_route("GET", "/hmp50/rare.json.gz")
  expect_identical(m$route$handler, "download_project_biom")
  expect_identical(m$params, list(access_key = "hmp50", file = "rare.json.gz"))

  # A literal segment wins over a parameter.
  m <- match_route("GET", "/unsaved/12abc/full.tab")
  expect_identical(m$route$handler, "download_draft_biom")
  expect_identical(m$params, list(session_key = "12abc", file = "full.tab"))

  expect_identical(match_route("GET", "/")$route$handler,       "serve_index")
  expect_identical(match_route("GET", "/hmp50")$route$handler,  "serve_index")
  expect_identical(match_route("GET", "/hmp50/")$route$handler, "serve_index")
})


test_that("match_route answers 404 and 405", {

  status <- function (method, path) expect_error(match_route(method, path), class = "atima_http_error")$status

  expect_identical(status("POST", "/api/no_such_thing"),     404L)
  expect_identical(status("POST", "/api/db_query"),          404L)
  expect_identical(status("POST", "/api/project"),           404L)
  expect_identical(status("POST", "/api/project/save/more"), 404L)
  expect_identical(status("POST", "/api/project/SAVE"),      404L)
  expect_identical(status("POST", "/api"),                   404L)
  expect_identical(status("POST", "/"),                      405L)
  expect_identical(status("POST", NULL),                     404L)
  expect_identical(status("GET",  "/a/b/c/d"),               404L)
  expect_identical(status("POST", "/hmp50/rare.json"),       404L)
  expect_identical(status("GET",  "/api/project/save"),      405L)

  # Old-style names are not routes any more.
  for (old in c("init_session", "jstree_move", "save_as", "update_permissions", "export"))
    expect_identical(status("POST", paste0("/api/", old)), 404L, info = old)

  # A GET to an API path is not an API call; it falls to the download
  # route, which refuses it at validation.
  m <- match_route("GET", "/api/plot")
  expect_identical(m$route$handler, "download_project_biom")
  expect_identical(expect_error(validate_args(m$route, m$params), class = "atima_http_error")$status, 400L)
})


# Argument validation ---------------------------------------------------------

test_that("every route refuses unknown arguments", {

  for (r in route_table()) {

    args <- valid_args[[r$endpoint]] %||% list()

    # The page a provider sends browsers back to takes what it knows and
    # ignores the rest.
    if (!r$strict) {
      expect_identical(r$endpoint, "GET /auth/callback")
      expect_identical(validate_args(r, list(code = "abc", state = "xyz", session_state = "extra")), list(code = "abc", state = "xyz"))
      next
    }

    for (extra in list(list(DB = "x"), list(REQ = "x"), list(user_id_ = 1), list(`__proto__` = "x"))) {
      err <- expect_error(validate_args(r, c(args, extra)), class = "atima_http_error", info = r$endpoint)
      expect_identical(err$status, 400L, info = r$endpoint)
      expect_match(conditionMessage(err), "Unknown argument", info = r$endpoint)
    }
  }
})


test_that("every route refuses a request that lacks a required argument", {

  for (r in route_table()) {

    args <- valid_args[[r$endpoint]] %||% list()

    for (key in required_args(r)) {
      err <- expect_error(
        validate_args(r, args[setdiff(names(args), key)]),
        class = "atima_http_error", info = paste(r$endpoint, key) )
      expect_identical(err$status, 400L)
      expect_identical(conditionMessage(err), sprintf("Missing argument '%s'.", key))
    }
  }
})


test_that("every route refuses arguments of the wrong type", {

  # Values that no argument type accepts.
  wrong <- list(NA, list(a = list(b = 1)), c("two", "strings"), function () 1)

  for (r in route_table()) {

    args <- valid_args[[r$endpoint]] %||% list()

    for (key in names(r$args)) {
      if (r$args[[key]]$type == "json") next
      for (value in wrong) {
        bad <- args; bad[[key]] <- value
        err <- expect_error(validate_args(r, bad), class = "atima_http_error", info = paste(r$endpoint, key))
        expect_identical(err$status, 400L)
        expect_match(conditionMessage(err), sprintf("^Argument '%s' ", key))
      }
    }
  }
})


test_that("validate_args refuses unnamed and repeated arguments", {

  r <- match_route("POST", "/api/project/rarefy")$route

  expect_error(validate_args(r, list(1000)),                     "must be named",   class = "atima_http_error")
  expect_error(validate_args(r, list(depth = 1000, 5)),          "must be named",   class = "atima_http_error")
  expect_error(validate_args(r, list(depth = 1000, depth = 50)), "was given twice", class = "atima_http_error")
})


test_that("validate_args returns cleaned values and fills in defaults", {

  r <- match_route("POST", "/api/project/export")$route
  expect_identical(
    validate_args(r, list(what = "taxa", rank = "Genus")),
    list(what = "taxa", sample_set = "full", format = "json", method = "bray", rank = "Genus") )

  r <- match_route("POST", "/api/project/save")$route
  expect_identical(
    validate_args(r, list(description = " <p>x</p> ", title = "  My study ")),
    list(title = "My study", description = "<p>x</p>") )

  # Optional arguments with no default are left out, so the handler's own
  # default applies.
  r <- match_route("POST", "/api/plot")$route
  args <- validate_args(r, list(plot_fn = "taxa_heatmap", plot_args = list(), depth = "250"))
  expect_identical(names(args), c("plot_fn", "plot_args", "depth", "attrs"))
  expect_identical(args$depth, 250L)
  expect_identical(args$attrs, FALSE)
})


test_that("argument types accept and refuse the right values", {

  ok  <- function (spec, x) spec$check(x)
  bad <- function (spec, x) expect_error(spec$check(x))

  # Strings
  expect_identical(ok(arg_string(), "  padded  "), "padded")
  expect_identical(ok(arg_string(trim = FALSE), " x "), " x ")
  expect_identical(ok(arg_string(min = 3, max = 5), "abc"), "abc")
  bad(arg_string(min = 3), "ab")
  bad(arg_string(min = 3), "  ab  ")
  bad(arg_string(max = 5), "abcdef")
  bad(arg_string(), 5)
  bad(arg_string(), NA_character_)
  bad(arg_string(), c("a", "b"))
  bad(arg_string(pattern = "^[a-z]+$"), "abc1")

  # Whole numbers
  expect_identical(ok(arg_int(), 5), 5L)
  expect_identical(ok(arg_int(), 5L), 5L)
  expect_identical(ok(arg_int(), "5"), 5L)
  expect_identical(ok(arg_int(), "-5"), -5L)
  bad(arg_int(), 5.5)
  bad(arg_int(), "5.5")
  bad(arg_int(), "five")
  bad(arg_int(), "1e3")
  bad(arg_int(), "99999999999999")
  bad(arg_int(), TRUE)
  bad(arg_int(), c(1, 2))
  bad(arg_int(), NA_integer_)
  bad(arg_int(), Inf)
  bad(arg_int(min = 1), 0)
  bad(arg_int(max = 10), 11)

  # Booleans
  expect_identical(ok(arg_bool(), TRUE), TRUE)
  expect_identical(ok(arg_bool(), "false"), FALSE)
  bad(arg_bool(), "yes")
  bad(arg_bool(), 1)
  bad(arg_bool(), NA)

  # Choices
  expect_identical(ok(arg_choice(c("a", "b")), "a"), "a")
  bad(arg_choice(c("a", "b")), "A")
  bad(arg_choice(c("a", "b")), "")
  bad(arg_choice(c("a", "b")), c("a", "b"))
  bad(arg_choice(c("a", "b")), 1)

  # Files
  upload <- list(filename = "x.biom", value = as.raw(1:3), content_type = "application/octet-stream")
  expect_identical(ok(arg_file(), upload), upload[c("filename", "value")])
  bad(arg_file(), "x.biom")
  bad(arg_file(), list(filename = "x.biom", value = "text"))
  bad(arg_file(), list(filename = "x.biom", value = raw(0)))
  bad(arg_file(), list(value = as.raw(1:3)))

  # Tree nodes
  expect_identical(ok(arg_node("CP"), "C12"), "C12")
  expect_identical(ok(arg_node("C", root = TRUE), "#"), "#")
  bad(arg_node("CP"), "G12")
  bad(arg_node("CP"), "#")
  bad(arg_node("CP"), "C")
  bad(arg_node("CP"), "C1; DROP TABLE users")
  bad(arg_node("CP"), "c12")
  bad(arg_node("CP"), 12)
})


test_that("allow-lists in the route table are enforced", {

  check <- function (path, args) {
    r <- match_route("POST", path)$route
    validate_args(r, args)
  }
  refused <- function (path, args, info = NULL)
    expect_error(check(path, args), "is not one of the allowed values", class = "atima_http_error", info = info)

  # Plot functions: nothing but the listed rbiom plots can be named.
  plot <- valid_args[["POST /api/plot"]]
  for (plot_fn in c("system", "write_biom", "adiv_boxplot; q()", "ggsave", "", "ADIV_BOXPLOT", "rbiom::adiv_boxplot"))
    refused("/api/plot", utils::modifyList(plot, list(plot_fn = plot_fn)), plot_fn)
  for (plot_fn in c("adiv_boxplot", "bdiv_ord_plot", "rare_multiplot", "taxa_heatmap"))
    expect_no_error(check("/api/plot", utils::modifyList(plot, list(plot_fn = plot_fn))))

  # Each allowed plot function is one rbiom really exports.
  plot_fns <- environment(match_route("POST", "/api/plot")$route$args$plot_fn$check)$choices
  expect_true(all(plot_fns %in% getNamespaceExports("rbiom")))

  # Upload components
  upload <- valid_args[["POST /api/project/upload_component"]]
  for (component in c("counts", "sequences", "id", "Metadata", "class"))
    refused("/api/project/upload_component", utils::modifyList(upload, list(component = component)), component)

  # Exports
  for (what in c("exe", "../../etc/passwd", "Biom", "sequences"))
    refused("/api/project/export", list(what = what), what)
  refused("/api/project/export", list(what = "biom", format = "exe"))
  refused("/api/project/export", list(what = "alpha", sample_set = "all"))
  for (rank in c("../etc", "a_b", "a/b", "a b", ""))
    expect_error(check("/api/project/export", list(what = "taxa", rank = rank)), class = "atima_http_error", info = rank)

  # Sharing
  for (permissions in c("owner", "admin", "EDIT", "", "view,edit"))
    refused("/api/sharing/update", list(user_id = 5, permissions = permissions), permissions)

  # Metadata field modes
  refused("/api/metadata/fields", list(mode = "everything"))
})


test_that("download file names and keys are restricted", {

  check <- function (path) {
    m <- match_route("GET", path)
    validate_args(m$route, m$params)
  }

  for (path in c("/hmp50/rare.json", "/hmp50/full.tab.gz", "/hmp50/rare.hdf5", "/my-study/full.json.bz2", "/unsaved/12abc/rare.tab"))
    expect_no_error(check(path))

  for (path in c(
      "/hmp50/rare.exe", "/hmp50/orig.json", "/hmp50/rare.json.zip", "/hmp50/rare", "/hmp50/RARE.json",
      "/hm/rare.json", "/-hmp50/rare.json", "/hmp50-/rare.json", "/hmp_50/rare.json", "/hmp50%2F../rare.json",
      "/unsaved/12-abc/rare.json", "/unsaved/12abc/rare.exe" ))
    expect_error(check(path), class = "atima_http_error", info = path)
})


# Permissions -----------------------------------------------------------------

# One project and a session for each kind of caller.
local_permission_setup <- function (env = parent.frame()) {

  REQ <- local_test_req(env)
  DB  <- REQ$DB

  users <- list(
    guest    = add_test_user(DB, "Guest 1", is_guest = TRUE),
    outsider = add_test_user(DB, "Olive Outsider"),
    viewer   = add_test_user(DB, "Victor Viewer"),
    editor   = add_test_user(DB, "Edith Editor"),
    admin    = add_test_user(DB, "Adam Admin", is_admin = TRUE) )

  project_id <- add_test_project(DB, users$editor)$project_id
  db_insert(DB, "permissions", "T1", user_id = users$viewer, project_id = project_id, is_editor = FALSE)
  db_insert(DB, "permissions", "T2", user_id = users$admin,  project_id = project_id, is_editor = TRUE)

  list(
    REQ        = REQ,
    app        = test_app(REQ),
    users      = users,
    project_id = project_id,
    sessions   = lapply(users, function (user_id) add_test_session(DB, user_id, project_id)) )
}

# Which callers each permission level lets through. "nobody" has no
# session; "guest" has not signed in and "outsider" has, and neither has
# been granted the project; the administrator is also one of its editors.
allowed <- list(
  public  = c("nobody", "guest", "outsider", "viewer", "editor", "admin"),
  session = c(          "guest", "outsider", "viewer", "editor", "admin"),
  viewer  = c(                               "viewer", "editor", "admin"),
  editor  = c(                                         "editor", "admin"),
  admin   = c(                                                   "admin") )


test_that("every route enforces its permission level before calling its handler", {

  setup  <- local_permission_setup()
  called <- NULL

  # The rules that look at arguments are tested on their own (test-access.R).
  local_mocked_bindings(
    check_rule   = function (...) invisible(TRUE),
    call_handler = function (route, REQ, args) {
      called <<- route$endpoint
      list(ok = TRUE)
    })

  for (r in route_table()) {
    for (caller in allowed$public) {

      called  <- NULL
      session <- if (caller == "nobody") NULL else setup$sessions[[caller]]
      resp    <- handle_request(route_request(r, valid_args[[r$endpoint]] %||% list(), session), setup$app)
      info    <- paste(r$endpoint, "as", caller)

      permitted <- caller %in% allowed[[r$permission]] && !(r$account && caller == "guest")

      if (permitted) {
        expect_identical(resp$status, 200L, info = info)
        expect_identical(called, r$endpoint, info = info)
      } else {
        expect_identical(resp$status, if (caller == "nobody") 401L else 403L, info = info)
        expect_null(called, info = info)
        expect_named(response_json(resp)$error, c("message", "id"), info = info)
      }
    }
  }
})


test_that("permission is checked before arguments are looked at", {

  setup <- local_permission_setup()
  local_mocked_bindings(call_handler = function (...) stop("handler reached"))

  # No session: a bad request still gets 401, not a description of the arguments.
  resp <- handle_request(fake_request("POST", "/api/project/save", list(nonsense = 1)), setup$app)
  expect_identical(resp$status, 401L)

  # A viewer cannot learn what an editor route expects.
  resp <- handle_request(fake_request("POST", "/api/project/save", list(nonsense = 1), setup$sessions$viewer), setup$app)
  expect_identical(resp$status, 403L)

  # An editor gets the validation error.
  resp <- handle_request(fake_request("POST", "/api/project/save", list(nonsense = 1), setup$sessions$editor), setup$app)
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "Unknown argument 'nonsense'")
})


test_that("sessions must present both the auth cookie and the session key", {

  setup <- local_permission_setup()
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  status <- function (session)
    handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), setup$app)$status

  good <- setup$sessions$viewer
  expect_identical(status(good), 200L)

  expect_identical(status(utils::modifyList(good, list(session_key = "nosuchkey"))), 401L)
  expect_identical(status(utils::modifyList(good, list(auth_token = random_string(64)))), 401L)
  expect_identical(status(utils::modifyList(good, list(auth_token = "short"))), 401L)

  # Another user's cookie with this session's key is not a session.
  mixed <- list(auth_token = setup$sessions$editor$auth_token, session_key = good$session_key)
  expect_identical(status(mixed), 401L)

  # A session that has been signed out is gone.
  db_query(
    setup$REQ$DB, "UPDATE sessions SET logout_utc = CURRENT_TIMESTAMP WHERE session_id = ?",
    "T1", list(good$session_id) )
  expect_identical(status(good), 401L)
})


test_that("access follows the project that is open in the session", {

  setup <- local_permission_setup()
  DB    <- setup$REQ$DB
  local_mocked_bindings(call_handler = function (...) list(ok = TRUE))

  status <- function (path, session, args = list())
    handle_request(fake_request("POST", path, args, session), setup$app)$status

  save_args <- valid_args[["POST /api/project/save"]]

  # A public project: anyone with a session can view, administrators can edit.
  public   <- add_test_project(DB, is_public = TRUE)$project_id
  outsider <- add_test_session(DB, setup$users$outsider, public)
  editor   <- add_test_session(DB, setup$users$editor,   public)
  admin    <- add_test_session(DB, setup$users$admin,    public)

  expect_identical(status("/api/metadata/thead", outsider), 200L)
  expect_identical(status("/api/project/save", outsider, save_args), 403L)
  expect_identical(status("/api/project/save", editor,   save_args), 403L)
  expect_identical(status("/api/project/save", admin,    save_args), 200L)

  # Being an administrator gives no access to other people's private projects.
  private <- add_test_project(DB, setup$users$editor)$project_id
  admin   <- add_test_session(DB, setup$users$admin, private)
  expect_identical(status("/api/sharing/list", admin), 403L)
  expect_identical(status("/api/project/publish", admin, list(is_public = TRUE)), 403L)

  # Publishing is for a project's editors, once they have signed in.
  editor <- add_test_session(DB, setup$users$editor, private)
  expect_identical(status("/api/project/publish", editor, list(is_public = TRUE)), 200L)
  db_insert(DB, "permissions", "T0", user_id = setup$users$guest, project_id = private, is_editor = TRUE)
  guest <- add_test_session(DB, setup$users$guest, private)
  expect_identical(status("/api/project/save", guest, save_args), 200L)
  expect_identical(status("/api/project/publish", guest, list(is_public = TRUE)), 403L)

  # Access is looked up on every request: a revoked grant stops working.
  viewer <- setup$sessions$viewer
  expect_identical(status("/api/sharing/list", viewer), 200L)
  db_query(DB, "DELETE FROM permissions WHERE user_id = ?", "T1", list(setup$users$viewer))
  expect_identical(status("/api/sharing/list", viewer), 403L)
  expect_identical(status("/api/session/heartbeat", viewer), 200L)
})


# Request handling ------------------------------------------------------------

test_that("handle_request parses JSON, form and multipart bodies", {

  setup <- local_permission_setup()
  seen  <- NULL
  local_mocked_bindings(call_handler = function (route, REQ, args) { seen <<- args; list(ok = TRUE) })

  session <- setup$sessions$editor
  send    <- function (...) handle_request(fake_request(..., session = session), setup$app)

  resp <- send("POST", "/api/project/rarefy", list(depth = 500))
  expect_identical(resp$status, 200L)
  expect_identical(seen, list(depth = 500L))

  resp <- send("POST", "/api/project/rarefy", charToRaw("depth=750"), content_type = "application/x-www-form-urlencoded")
  expect_identical(resp$status, 200L)
  expect_identical(seen, list(depth = 750L))

  # An empty body is no arguments.
  resp <- send("POST", "/api/session/heartbeat", NULL)
  expect_identical(resp$status, 200L)
  expect_identical(seen, list())

  form <- multipart_body(list(
    component      = "taxonomy",
    component_file = list(filename = "taxa.csv", value = charToRaw("otu,genus\n1,Bacteroides\n")) ))
  resp <- send("POST", "/api/project/upload_component", form$body, content_type = form$content_type)
  expect_identical(resp$status, 200L)
  expect_identical(seen$component, "taxonomy")
  expect_identical(seen$component_file$filename, "taxa.csv")
  expect_identical(rawToChar(seen$component_file$value), "otu,genus\n1,Bacteroides\n")
})


test_that("handle_request answers 400 to bodies it cannot read", {

  setup   <- local_permission_setup()
  local_mocked_bindings(call_handler = function (...) stop("handler reached"))
  session <- setup$sessions$editor

  status <- function (body, content_type = "application/json")
    handle_request(fake_request("POST", "/api/project/rarefy", body, session, content_type = content_type), setup$app)$status

  expect_identical(status(charToRaw("{not json")), 400L)
  expect_identical(status(charToRaw("[1000]")), 400L)
  expect_identical(status(charToRaw("1000")), 400L)
  expect_identical(status(charToRaw("null")), 400L)
  expect_identical(status(charToRaw("depth=1000"), "text/plain"), 400L)
  expect_identical(status(charToRaw("depth=1000"), NULL), 400L)
  expect_identical(status(list(depth = "deep")), 400L)
})


test_that("a handler that fails leaves no changes in the database", {

  setup <- local_permission_setup()
  DB    <- setup$REQ$DB

  local_mocked_bindings(call_handler = function (route, REQ, args) {
    db_query(REQ$DB, "UPDATE projects SET title = 'Half-finished change'", "T1")
    add_test_user(REQ$DB, "Created by a failing handler")
    stop("failed halfway")
  })

  resp <- handle_request(fake_request("POST", "/api/session/heartbeat", list(), setup$sessions$editor), setup$app)

  expect_identical(resp$status, 500L)
  expect_identical(db_query(DB, "SELECT title FROM projects", "T2"), "Test project")
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM users", "T3"), 5L)
})


test_that("the index page is served for the app's own URLs", {

  REQ <- local_test_req()

  for (path in c("/", "/hmp50", "/some-project/")) {
    resp <- handle_request(fake_request("GET", path), test_app(REQ))
    expect_identical(resp$status, 200L, info = path)
    expect_match(resp$headers[['Content-Type']], "text/html", info = path)
  }
})
