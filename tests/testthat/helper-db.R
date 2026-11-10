# A new, fully migrated atima database in a temporary data directory, wrapped
# in the `REQ` environment that request handlers expect. Everything is
# removed when the calling test finishes.
local_test_req <- function (env = parent.frame()) {

  data_dir <- withr::local_tempdir(pattern = "atima_test_", .local_envir = env)
  dir.create(file.path(data_dir, "files"))
  dir.create(file.path(data_dir, "cache"))

  DB <- db_open(data_dir)
  withr::defer(db_close(DB), envir = env)

  as.environment(list(
    DB      = DB,
    CONFIG  = list(data_dir = data_dir, temp_dir = data_dir, cache_size = 1e8),
    SESSION = list() ))
}


# The `app` argument of handle_request() for a test REQ.
test_app <- function (REQ) {
  list(db = REQ$DB, config = REQ$CONFIG)
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
    access_key = random_string(12),
    is_public  = is_public )

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

  auth_token <- random_string(64)

  auth_token_id <- db_insert(
    DB = DB, table = "auth_tokens", err_code = "TSess1",
    user_id = user_id, auth_token_sha = as.character(openssl::sha256(auth_token)) )

  session_key <- random_string(12)

  session_id <- db_insert(
    DB = DB, table = "sessions", err_code = "TSess2",
    auth_token_id = auth_token_id, user_id = user_id,
    draft_id      = create_draft(DB, project_id),
    ip_address    = "127.0.0.1", session_key = session_key )

  list(auth_token = auth_token, session_key = session_key, session_id = session_id)
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
