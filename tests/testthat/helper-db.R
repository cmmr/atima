# An empty atima database in a temporary data directory, wrapped in the `REQ`
# environment that request handlers expect. Everything is removed when the
# calling test finishes.
local_test_req <- function (env = parent.frame()) {

  data_dir <- withr::local_tempdir(pattern = "atima_test_", .local_envir = env)
  dir.create(file.path(data_dir, "files"))
  dir.create(file.path(data_dir, "cache"))

  DB <- db_connect(data_dir)
  withr::defer(db_close(DB), envir = env)
  utils::capture.output(init_db_structure(DB))

  as.environment(list(
    DB      = DB,
    CONFIG  = list(data_dir = data_dir, temp_dir = data_dir, cache_size = 1e8),
    SESSION = list() ))
}


# Add a registered (non-guest) or guest user; returns the user_id.
add_test_user <- function (DB, full_name, is_guest = FALSE) {
  db_insert(DB, "users", "TUser", full_name = full_name, is_guest = is_guest)
}


# Add a project row that points at the placeholder biom file (id 0), and make
# `user_id` its editor or viewer. Returns list(project_id, permission_id).
add_test_project <- function (DB, user_id, title = "Test project", is_editor = TRUE, collection_id = NULL) {

  project_id <- db_insert(
    DB = DB, table = "projects", err_code = "TProj1",
    title      = title,
    orig_bf_id = 0L, full_bf_id = 0L, rare_bf_id = 0L,
    access_key = random_string(12) )

  permission_id <- db_insert(
    DB = DB, table = "permissions", err_code = "TProj2",
    user_id = user_id, project_id = project_id,
    collection_id = collection_id, is_editor = is_editor )

  list(project_id = project_id, permission_id = permission_id)
}
