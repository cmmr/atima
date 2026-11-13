# The OpenID Connect client settings that tests run with. No such provider
# exists; tests that sign in put a mock one in its place (helper-oidc.R).
test_oidc <- list(
  issuer        = "https://issuer.test",
  client_id     = "atima-test-client",
  client_secret = "test-client-secret-not-a-real-one",
  redirect_uri  = "http://localhost:8080/auth/callback",
  admins        = NULL )


# A new, fully migrated atima database in a temporary data directory, wrapped
# in the `REQ` environment that request handlers expect. Everything is
# removed when the calling test finishes.
local_test_req <- function (env = parent.frame(), auth = "oidc") {

  data_dir <- withr::local_tempdir(pattern = "atima_test_", .local_envir = env)
  temp_dir <- withr::local_tempdir(pattern = "atima_temp_", .local_envir = env)
  dir.create(file.path(data_dir, "files"))
  dir.create(file.path(data_dir, "cache"))

  DB <- db_open(data_dir)
  withr::defer(db_close(DB), envir = env)

  as.environment(list(
    DB      = DB,
    CONFIG  = list(
      data_dir    = normalizePath(data_dir, winslash = "/"),
      temp_dir    = normalizePath(temp_dir, winslash = "/"),
      cache_size  = 1e8,
      max_cpus    = 1L,
      session_ttl = 24 * 3600,
      guest_ttl   = 30 * 86400,
      signin_ttl  = 30 * 86400,
      auth        = auth ),
    MEMO    = memo_new(),
    LEGACY  = legacy_state(),
    AUTH    = auth_new(auth, if (auth == "oidc") test_oidc),
    SESSION = list() ))
}


# The `app` argument of handle_request() for a test REQ. Without a `pool`,
# jobs run in the test process.
test_app <- function (REQ, pool = NULL) {
  list(db = REQ$DB, config = REQ$CONFIG, pool = pool, memo = REQ$MEMO, auth = REQ$AUTH, legacy = REQ$LEGACY)
}


# A worker pool with a compute profile of its own. Called at the top of a
# test file, it serves every test in the file and is stopped when the file
# ends. Under devtools::test() the workers load atima from source, as the
# test process did; under R CMD check they use the installed package.
local_test_pool <- function (workers = 2L, time_limit = 5, grace = 1, ..., env = parent.frame()) {

  profile <- paste0("atima-test-", random_string(8))

  testthat::skip_on_cran()

  init <- NULL

  if (pkgload::is_dev_package("atima")) {
    init <- function () {
      if (!isNamespaceLoaded("atima"))
        pkgload::load_all(path, quiet = TRUE, attach = FALSE, helpers = FALSE, attach_testthat = FALSE)
    }
    environment(init) <- list2env(list(path = pkgload::pkg_path()), parent = baseenv())
  }

  pool <- pool_start(workers = workers, time_limit = time_limit, grace = grace, init = init, profile = profile, ...)
  withr::defer(pool_stop(pool), envir = env)

  pool
}


# Wait for a promise, keeping the event loop turning. Returns
# list(value = ) or list(error = ), or fails if it takes too long.
await <- function (promise, seconds = 60) {

  result <- NULL

  promises::then(
    promise,
    onFulfilled = function (value) result <<- list(value = value),
    onRejected  = function (error) result <<- list(error = error) )

  deadline <- Sys.time() + seconds
  while (is.null(result) && Sys.time() < deadline) later::run_now(timeoutSecs = 0.05)

  if (is.null(result)) stop("The promise did not settle within ", seconds, " seconds.")

  result
}


# Wait until `condition()` is TRUE, keeping the event loop turning.
wait_until <- function (condition, seconds = 30) {
  deadline <- Sys.time() + seconds
  while (!condition() && Sys.time() < deadline) later::run_now(timeoutSecs = 0.05)
  condition()
}


# A job for a worker that evaluates `expr` there. `eval` is found from the
# package namespace like any worker function, so tests need no hook in the
# package to run something slow, something that fails, or something that
# takes the worker down.
eval_job <- function (expr, finish = function (result) result) {
  job("eval", list(expr = expr), finish)
}


# Add a registered (non-guest) or guest user; returns the user_id.
add_test_user <- function (DB, full_name, is_guest = FALSE, is_admin = FALSE) {
  db_insert(DB, "users", "TUser", full_name = full_name, is_guest = is_guest, is_admin = is_admin)
}


# Add a row to biom_files that points at no real file; returns its id.
add_test_biom_file <- function (DB) {
  db_insert(DB, "biom_files", "TFile", file = paste0(random_string(10), ".biom"), hash = random_string(10))
}


# Add a project row whose BIOM files are placeholders. With a `user_id`, that
# user becomes its editor or viewer. Returns list(project_id, permission_id).
add_test_project <- function (
    DB, user_id = NULL, title = "Test project", is_editor = TRUE,
    collection_id = NULL, is_public = FALSE ) {

  bf_id <- add_test_biom_file(DB)

  project_id <- db_insert(
    DB = DB, table = "projects", err_code = "TProj1",
    title      = title,
    orig_bf_id = bf_id, full_bf_id = bf_id, rare_bf_id = bf_id,
    access_key = random_key(12),
    public_key = if (is_public) random_key(8) )

  permission_id <- NULL
  if (!is.null(user_id))
    permission_id <- db_insert(
      DB = DB, table = "permissions", err_code = "TProj2",
      user_id = user_id, project_id = project_id,
      collection_id = collection_id, is_editor = is_editor )

  list(project_id = project_id, permission_id = permission_id)
}


# Open a session for `user_id` on `project_id`, the way api_init_session()
# does. Returns the credentials a browser would hold.
add_test_session <- function (DB, user_id, project_id) {

  token      <- auth_token_new(DB, user_id, ttl = 3600)
  auth_token <- token$auth_token

  session_key <- random_string(12)

  session_id <- db_insert(
    DB = DB, table = "sessions", err_code = "TSess2",
    auth_token_id = token$auth_token_id, user_id = user_id,
    draft_id      = create_draft(DB, project_id),
    ip_address    = "127.0.0.1", session_key = session_key )

  list(auth_token = auth_token, session_key = session_key, session_id = session_id)
}


# Let sessions open on test projects whose BIOM files are placeholders: the
# summary a worker would compute from the files is left empty.
local_fake_biom <- function (env = parent.frame()) {
  testthat::local_mocked_bindings(
    with_biom_data = function (REQ, then) then(session_biom(REQ, list())),
    .env = env )
}


# The credentials a response from /api/session/init hands to the browser.
session_from <- function (resp) {
  list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )
}


# A request as httpuv would hand it to the app.
#   body     a named list (sent as JSON), or a raw vector with `content_type`
#   session  from add_test_session(), or NULL for a visitor with no session
fake_request <- function (
    method, path, body = NULL, session = NULL, query = "",
    content_type = "application/json" ) {

  if (is.list(body))
    body <- charToRaw(as.character(jsonlite::toJSON(body, auto_unbox = TRUE)))

  list(
    REQUEST_METHOD = method,
    PATH_INFO      = path,
    QUERY_STRING   = query,
    CONTENT_TYPE   = content_type,
    HTTP_HOST      = "127.0.0.1:8080",
    REMOTE_ADDR    = "127.0.0.1",
    HTTP_COOKIE    = if (!is.null(session)) paste0("auth_token=", session$auth_token),
    HEADERS        = if (!is.null(session)) c('x-session-key' = session$session_key) else character(0),
    rook.input     = list(read = function () body) )
}


# A multipart/form-data body. `fields` is a named list of strings and of
# list(filename, value = <raw>) for files.
# Returns list(body = <raw>, content_type).
multipart_body <- function (fields) {

  boundary <- "----atimatestboundary"
  body     <- raw(0)

  for (name in names(fields)) {
    field <- fields[[name]]
    head  <- sprintf('--%s\r\nContent-Disposition: form-data; name="%s"', boundary, name)
    if (is.list(field)) {
      head  <- paste0(head, sprintf('; filename="%s"\r\nContent-Type: application/octet-stream', field$filename))
      value <- field$value
    } else {
      value <- charToRaw(field)
    }
    body <- c(body, charToRaw(paste0(head, "\r\n\r\n")), value, charToRaw("\r\n"))
  }

  body <- c(body, charToRaw(sprintf("--%s--\r\n", boundary)))

  list(body = body, content_type = paste0("multipart/form-data; boundary=", boundary))
}


# The parsed JSON body of a response.
response_json <- function (resp) {
  jsonlite::fromJSON(resp$body, simplifyVector = FALSE)
}


# What a database's schema says, independent of how the CREATE statements
# were formatted: columns, foreign keys and indexes of every table.
db_schema_summary <- function (DB) {

  tables <- sort(DBI::dbListTables(DB))
  tables <- tables[!startsWith(tables, "sqlite_")]

  lapply(stats::setNames(nm = tables), function (table) {

    columns <- DBI::dbGetQuery(DB, sprintf("PRAGMA table_info(%s)", table))
    columns <- columns[order(columns$name), c("name", "type", "notnull", "dflt_value", "pk")]

    fkeys <- DBI::dbGetQuery(DB, sprintf("PRAGMA foreign_key_list(%s)", table))
    fkeys <- fkeys[order(fkeys$from), c("table", "from", "to", "on_update", "on_delete")]

    indexes <- DBI::dbGetQuery(DB, sprintf("PRAGMA index_list(%s)", table))
    indexes <- indexes[order(indexes$name), c("name", "unique")]
    indexes$columns <- vapply(indexes$name, FUN.VALUE = character(1), function (index) {
      paste(DBI::dbGetQuery(DB, sprintf("PRAGMA index_info(%s)", index))$name, collapse = ",") })

    rownames(columns) <- rownames(fkeys) <- rownames(indexes) <- NULL

    list(columns = columns, foreign_keys = fkeys, indexes = indexes)
  })
}


# Send the server log to a file for the rest of the calling test, and return
# a function that reads it back as a list of entries.
local_log <- function (env = parent.frame()) {
  file <- withr::local_tempfile(.local_envir = env)
  withr::local_options(atima.log = file, .local_envir = env)
  function () {
    if (!file.exists(file)) return (list())
    lapply(readLines(file), jsonlite::fromJSON, simplifyVector = FALSE)
  }
}

log_errors <- function (entries) Filter(function (e) e$event == "error", entries)


# The names of the metadata fields in a `BIOM` reply.
field_names <- function (BIOM) vapply(BIOM$fields, function (f) f$name, character(1))


# A seeded database and a guest session on hmp50. Jobs run in the test
# process.
local_open_project <- function (env = parent.frame()) {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req(env)
  db_seed(REQ$DB, REQ$CONFIG)

  app  <- test_app(REQ)
  resp <- handle_request(fake_request("POST", "/api/session/init", list()), app)

  session <- list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )

  list(
    REQ     = REQ,
    DB      = REQ$DB,
    app     = app,
    session = session,
    BIOM    = response_json(resp)$BIOM,
    post    = function (path, args = list()) handle_request(fake_request("POST", path, args, session), app),
    upload  = function (file, name, ...) {
      form <- multipart_body(list(biom_file = list(filename = name, value = read_file_raw(file)), ...))
      handle_request(fake_request("POST", "/api/project/upload", form$body, session, content_type = form$content_type), app)
    },
    temp    = file.path(REQ$CONFIG$temp_dir, session$session_key) )
}
