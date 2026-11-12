# The database layer: connection settings, schema migrations, transactions
# and the query helpers.


# A data directory holding a database exactly as atima 5.0.x left it.
local_legacy_data_dir <- function (env = parent.frame()) {

  data_dir <- withr::local_tempdir(pattern = "atima_legacy_", .local_envir = env)

  old <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  for (sql in sql_statements(test_path("fixtures", "atima-5.0.sql")))
    DBI::dbExecute(old, sql)
  DBI::dbDisconnect(old)

  data_dir
}

latest_version <- function () max(db_migrations()$version)


# Connection ------------------------------------------------------------------

test_that("db_open sets the connection up for a long-lived server", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  expect_identical(DBI::dbGetQuery(DB, "PRAGMA journal_mode")[[1]], "wal")
  expect_identical(as.integer(DBI::dbGetQuery(DB, "PRAGMA foreign_keys")[[1]]), 1L)
  expect_identical(as.integer(DBI::dbGetQuery(DB, "PRAGMA busy_timeout")[[1]]), 5000L)
})


# Fresh install ---------------------------------------------------------------

test_that("a new database gets the latest schema and no placeholder rows", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  expect_identical(db_version(DB), latest_version())

  expect_setequal(
    DBI::dbListTables(DB),
    c("auth_tokens", "biom_files", "collections", "drafts", "last_access",
      "permissions", "projects", "sessions", "users") )

  for (table in DBI::dbListTables(DB))
    expect_identical(
      DBI::dbGetQuery(DB, sprintf("SELECT COUNT(*) FROM %s", table))[[1]], 0L, info = table )

  expect_true(db_is_empty(DB))

  # No backup is made of a database that held nothing.
  expect_length(list.files(REQ$CONFIG$data_dir, pattern = "\\.bak$"), 0)
})


test_that("the schema has the public-project columns, delete rules and indexes", {

  REQ    <- local_test_req()
  schema <- db_schema_summary(REQ$DB)

  expect_true(all(c("public_key", "public_collection_id") %in% schema$projects$columns$name))

  # Nothing about passwords is left, and users have an identity instead.
  expect_false(any(c("password", "alt_password", "n_attempts", "locked_utc") %in% schema$users$columns$name))
  expect_true(all(c("issuer", "sub") %in% schema$users$columns$name))
  expect_true("expires_utc" %in% schema$auth_tokens$columns$name)

  unique_index <- function (table, columns) {
    idx <- schema[[table]]$indexes
    any(idx$columns == columns & idx$unique == 1)
  }
  expect_true(unique_index("users", "issuer,sub"))
  expect_true(unique_index("projects", "access_key"))
  expect_true(unique_index("projects", "public_key"))
  expect_false(unique_index("users", "email"))

  rule <- function (table, from) {
    fk <- schema[[table]]$foreign_keys
    fk$on_delete[fk$from == from]
  }

  # Every foreign key says what happens when its target is deleted.
  for (table in names(schema))
    expect_false(any(schema[[table]]$foreign_keys$on_delete == "NO ACTION"), info = table)

  expect_identical(rule("permissions", "user_id"),         "CASCADE")
  expect_identical(rule("permissions", "project_id"),      "CASCADE")
  expect_identical(rule("permissions", "collection_id"),   "SET NULL")
  expect_identical(rule("permissions", "grantor_user_id"), "SET NULL")
  expect_identical(rule("drafts",      "project_id"),      "CASCADE")
  expect_identical(rule("projects",    "full_bf_id"),      "RESTRICT")
  expect_identical(rule("sessions",    "user_id"),         "SET NULL")
  expect_identical(rule("sessions",    "draft_id"),        "SET NULL")
  expect_identical(rule("collections", "user_id"),         "CASCADE")

  # Every foreign key column is the first column of some index.
  for (table in names(schema)) {
    indexed <- sub(",.*$", "", schema[[table]]$indexes$columns)
    for (column in schema[[table]]$foreign_keys$from)
      if (!column %in% c("orig_bf_id", "full_bf_id", "rare_bf_id"))
        expect_true(column %in% indexed, info = paste(table, column))
  }
})


test_that("foreign keys are enforced and deletes cascade", {

  REQ   <- local_test_req()
  DB    <- REQ$DB
  ada   <- add_test_user(DB, "Ada Lovelace")
  coll  <- create_collection(DB, ada, NULL, "My studies")
  proj  <- add_test_project(DB, ada, collection_id = coll)
  sess  <- add_test_session(DB, ada, proj$project_id)

  count <- function (table) DBI::dbGetQuery(DB, sprintf("SELECT COUNT(*) FROM %s", table))[[1]]

  # Rows cannot point at things that do not exist.
  expect_error(
    db_insert(DB, "permissions", "Test1", user_id = 999L, project_id = proj$project_id),
    class = "atima_db_error" )

  # A BIOM file in use cannot be deleted.
  expect_error(db_query(DB, "DELETE FROM biom_files", "Test2"), class = "atima_db_error")

  # Deleting a collection keeps the project, at the top level.
  db_query(DB, "DELETE FROM collections WHERE collection_id = ?", "Test3", list(coll))
  expect_true(is.na(db_query(DB, "SELECT collection_id FROM permissions", "Test4")))

  # Deleting the user removes what was theirs; the session row survives
  # without a user, and the project itself is left for the cleanup job.
  db_query(DB, "DELETE FROM users WHERE user_id = ?", "Test5", list(ada))
  expect_identical(count("permissions"), 0L)
  expect_identical(count("auth_tokens"), 0L)
  expect_identical(count("projects"),    1L)
  session <- db_query(DB, "SELECT user_id, auth_token_id, draft_id FROM sessions", "Test6")
  expect_true(is.na(session$user_id))
  expect_true(is.na(session$auth_token_id))
  expect_false(is.na(session$draft_id))

  # Deleting the project removes its drafts.
  db_query(DB, "DELETE FROM projects", "Test7")
  expect_identical(count("drafts"), 0L)
  expect_true(is.na(db_query(DB, "SELECT draft_id FROM sessions", "Test8")))
})


# Upgrade from 5.0.x ----------------------------------------------------------

test_that("a 5.0.x database is upgraded in place", {

  data_dir <- local_legacy_data_dir()
  DB       <- db_open(data_dir)
  withr::defer(db_close(DB))

  q <- function (sql) DBI::dbGetQuery(DB, sql)

  expect_identical(db_version(DB), latest_version())
  expect_identical(nrow(q("PRAGMA foreign_key_check")), 0L)
  expect_false(any(startsWith(DBI::dbListTables(DB), "migration_")))

  # Placeholder rows are gone; real rows are kept.
  expect_identical(q("SELECT user_id FROM users ORDER BY user_id")[[1]], 1001:1003)
  expect_identical(q("SELECT biom_file_id FROM biom_files ORDER BY 1")[[1]], 1:3)
  expect_identical(q("SELECT project_id FROM projects ORDER BY 1")[[1]], 10001:10003)
  expect_identical(q("SELECT email FROM users WHERE user_id = 1001")[[1]], "ada@example.org")
  expect_identical(q("SELECT n_views FROM projects WHERE project_id = 10001")[[1]], 12L)

  # "User 0" permissions made a project public, with its place in the tree.
  # A public project now goes by its old address as its public key, and has
  # a new random private key. A private project with a long key keeps it.
  projects <- q("SELECT project_id, access_key, public_key, public_collection_id FROM projects ORDER BY 1")
  expect_identical(projects$public_key, c("hmp50", NA, "toplevel"))
  expect_identical(projects$public_collection_id, c(4L, NA, NA))
  expect_identical(projects$access_key[[2]], "Xk3pQ9wLm2Za")
  expect_match(projects$access_key[c(1, 3)], "^[a-z0-9]{12}$")
  expect_identical(anyDuplicated(projects$access_key), 0L)

  # Accounts keep their rows, but have no identity to sign in with yet.
  users <- q("SELECT user_id, issuer, sub, is_guest, is_admin FROM users ORDER BY 1")
  expect_identical(users$is_guest, c(0L, 0L, 1L))
  expect_identical(users$is_admin, c(1L, 0L, 0L))
  expect_true(all(is.na(users$issuer)) && all(is.na(users$sub)))

  # The cookie of a password account stops working; a guest's now expires.
  tokens <- q("SELECT auth_token_id, user_id, expires_utc FROM auth_tokens")
  expect_identical(tokens$user_id, 1003L)
  expect_gt(as.numeric(as.POSIXct(tokens$expires_utc, tz = "UTC")), as.numeric(Sys.time()) + 29 * 86400)

  # "User 0" collections became public collections.
  collections <- q("SELECT collection_id, user_id, parent_collection_id FROM collections ORDER BY 1")
  expect_identical(collections$user_id, c(NA, 1001L, 1002L, NA))
  expect_identical(collections$parent_collection_id, c(NA, NA, NA, 1L))

  # Real grants are kept; user 0's and the one for a missing user are not.
  # Dangling optional references are cleared.
  permissions <- q("SELECT * FROM permissions ORDER BY permission_id")
  expect_identical(permissions$permission_id,   c(2L, 3L, 5L, 7L))
  expect_identical(permissions$user_id,         c(1001L, 1002L, 1001L, 1003L))
  expect_identical(permissions$collection_id,   c(2L, 3L, NA, NA))
  expect_identical(permissions$is_editor,       c(1L, 0L, 1L, 0L))
  expect_identical(permissions$grantor_user_id, c(NA, 1001L, NA, NA))

  expect_identical(q("SELECT draft_id FROM drafts ORDER BY 1")[[1]], 1:2)

  sessions <- q("SELECT * FROM sessions ORDER BY session_id")
  expect_identical(sessions$session_key,   c("1abcdefgh", "2abcdefgh"))
  expect_identical(sessions$user_id,       c(1001L, 1003L))
  expect_identical(sessions$auth_token_id, c(NA_integer_, NA_integer_))
  expect_false(is.na(sessions$logout_utc[[1]]))
  expect_identical(sessions$draft_id,      c(2L, NA))

  last_access <- q("SELECT * FROM last_access")
  expect_identical(last_access$user_id,    1001L)
  expect_identical(last_access$is_starred, 1L)
  expect_identical(last_access$viewed_utc, "2025-03-01 10:00:00")

  # The permission rules give the same answers as before the upgrade.
  expect_identical(project_access(DB, 10001L, 1003L), "viewer")   # public
  expect_identical(project_access(DB, 10001L, 1002L), "viewer")   # public
  expect_identical(project_access(DB, 10001L, 1001L), "editor")   # public + admin
  expect_identical(project_access(DB, 10002L, 1001L), "editor")
  expect_identical(project_access(DB, 10002L, 1002L), "viewer")
  expect_identical(project_access(DB, 10002L, 1003L), "none")
  expect_identical(project_access(DB, 10002L, NULL),  "none")
})


test_that("the upgrade to version 4 drops passwords and replaces guessable private keys", {

  data_dir <- withr::local_tempdir(pattern = "atima_v3_")
  DB       <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(DB))

  # A version 3 database, as step 4 left it, with what version 4 changes.
  db_migrate(DB, data_dir, db_migrations()[1:3, ])
  expect_identical(db_version(DB), 3L)

  run <- function (sql) DBI::dbExecute(DB, sql)
  q   <- function (sql) DBI::dbGetQuery(DB, sql)

  run("INSERT INTO users (user_id, full_name, email, password, alt_password, n_attempts, is_guest) VALUES (1, 'Ada Lovelace', 'ada@example.org', 'a-stored-password-hash', 'a-reset-password-hash', 2, 0)")
  run("INSERT INTO users (user_id, full_name, email, is_guest) VALUES (2, 'Ada Lovelace', 'ada+2@example.org', 0)")
  run("INSERT INTO users (user_id, full_name) VALUES (3, 'Guest 3')")
  run("INSERT INTO biom_files (biom_file_id, file, hash) VALUES (1, 'a.biom', 'a')")

  keys <- c(short = "abcd", eleven = "elevenchars", long = "Xk3pQ9wLm2Za", custom = "my-long-custom-key", public = "hmp50")
  for (i in seq_along(keys))
    run(sprintf(
      "INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, is_public) VALUES (%i, 'P', 1, 1, 1, '%s', %i)",
      i, keys[[i]], names(keys)[[i]] == "public" ))

  run("INSERT INTO permissions (user_id, project_id) VALUES (1, 1)")
  run("INSERT INTO auth_tokens (auth_token_id, auth_token_sha, user_id) VALUES (1, 'sha-user', 1)")
  run("INSERT INTO auth_tokens (auth_token_id, auth_token_sha, user_id) VALUES (2, 'sha-guest', 3)")

  db_migrate(DB, data_dir)
  expect_identical(db_version(DB), latest_version())

  # Every row is still there; the password columns are not, anywhere.
  users <- q("SELECT * FROM users ORDER BY user_id")
  expect_identical(users$full_name, c("Ada Lovelace", "Ada Lovelace", "Guest 3"))
  expect_identical(users$email, c("ada@example.org", "ada+2@example.org", NA))
  expect_false(any(grepl("password|attempts|locked", names(users))))
  expect_no_match(paste(unlist(q("SELECT sql FROM sqlite_master")), collapse = " "), "password")
  expect_identical(q("SELECT user_id FROM permissions")[[1]], 1L)

  # The hashes are kept in the backup, for claiming the account later.
  backup <- list.files(data_dir, pattern = "^sqlite\\.db\\.v3\\..*\\.bak$", full.names = TRUE)
  expect_length(backup, 1)
  old <- DBI::dbConnect(RSQLite::SQLite(), backup)
  withr::defer(DBI::dbDisconnect(old))
  expect_identical(DBI::dbGetQuery(old, "SELECT password FROM users WHERE user_id = 1")[[1]], "a-stored-password-hash")

  # Two accounts may now have one email address.
  expect_no_error(run("UPDATE users SET email = 'ada@example.org' WHERE user_id = 2"))

  # ...but not one identity.
  run("UPDATE users SET issuer = 'https://issuer.test', sub = 'sub-1' WHERE user_id = 1")
  expect_error(run("UPDATE users SET issuer = 'https://issuer.test', sub = 'sub-1' WHERE user_id = 2"), "UNIQUE")

  # Private keys shorter than twelve characters were replaced; longer ones,
  # which old links may use, were kept. The public project's address is now
  # its public key, and it has a private key like everyone else.
  projects <- q("SELECT access_key, public_key FROM projects ORDER BY project_id")
  expect_identical(projects$public_key, c(NA, NA, NA, NA, "hmp50"))
  expect_identical(projects$access_key[3:4], c("Xk3pQ9wLm2Za", "my-long-custom-key"))
  expect_match(projects$access_key[c(1, 2, 5)], "^[a-z0-9]{12}$")
  expect_false(any(projects$access_key %in% keys[c("short", "eleven", "public")]))
  expect_identical(anyDuplicated(projects$access_key), 0L)

  # Only the guest is still signed in.
  expect_identical(q("SELECT user_id FROM auth_tokens")[[1]], 3L)
})


test_that("an upgraded database has the same schema as a new one", {

  fresh    <- local_test_req()
  upgraded <- db_open(local_legacy_data_dir())
  withr::defer(db_close(upgraded))

  expect_identical(db_schema_summary(upgraded), db_schema_summary(fresh$DB))
})


test_that("the old database is backed up before it is upgraded", {

  data_dir <- local_legacy_data_dir()
  db_close(db_open(data_dir))

  backup <- list.files(data_dir, pattern = "^sqlite\\.db\\.v0\\..*\\.bak$", full.names = TRUE)
  expect_length(backup, 1)

  # The backup is the database as it was, unclaimed atima 2 data included.
  old <- DBI::dbConnect(RSQLite::SQLite(), backup)
  withr::defer(DBI::dbDisconnect(old))

  expect_identical(as.integer(DBI::dbGetQuery(old, "PRAGMA user_version")[[1]]), 0L)
  expect_identical(DBI::dbGetQuery(old, "SELECT COUNT(*) FROM migration_objects")[[1]], 1L)
  expect_identical(DBI::dbGetQuery(old, "SELECT COUNT(*) FROM users WHERE user_id = 0")[[1]], 1L)

  # Opening an up-to-date database changes nothing and makes no new backup.
  DB <- db_open(data_dir)
  withr::defer(db_close(DB))
  expect_identical(db_version(DB), latest_version())
  expect_length(list.files(data_dir, pattern = "\\.bak$"), 1)
})


test_that("a failed migration leaves the database as it was", {

  data_dir <- local_legacy_data_dir()
  scripts  <- withr::local_tempdir()

  file.copy(db_migrations()$file[[1]], scripts)
  writeLines(
    c("DROP TABLE migration_objects;", "DELETE FROM users;", "INSERT INTO no_such_table VALUES (1);"),
    file.path(scripts, "002_broken.sql") )

  DB <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(DB))

  expect_error(
    db_migrate(DB, data_dir, db_migrations(scripts)),
    "002_broken.sql failed and was rolled back" )

  expect_identical(db_version(DB), 1L)
  expect_true("migration_objects" %in% DBI::dbListTables(DB))
  expect_identical(DBI::dbGetQuery(DB, "SELECT COUNT(*) FROM users")[[1]], 5L)
})


test_that("a migration that would break a foreign key is refused", {

  data_dir <- local_legacy_data_dir()
  scripts  <- withr::local_tempdir()

  file.copy(db_migrations()$file[[1]], scripts)
  writeLines("DELETE FROM users WHERE user_id = 1001;", file.path(scripts, "002_orphans.sql"))

  DB <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(DB))

  expect_error(db_migrate(DB, data_dir, db_migrations(scripts)), "break a foreign key")
  expect_identical(DBI::dbGetQuery(DB, "SELECT COUNT(*) FROM users WHERE user_id = 1001")[[1]], 1L)
})


test_that("a database from a newer atima is refused", {

  data_dir <- withr::local_tempdir()
  DB <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  DBI::dbExecute(DB, sprintf("PRAGMA user_version = %i", latest_version() + 1L))
  DBI::dbDisconnect(DB)

  expect_error(db_open(data_dir), "Install a newer atima")
})


test_that("migration scripts are numbered without gaps", {

  expect_identical(db_migrations()$version, seq_len(nrow(db_migrations())))

  scripts <- withr::local_tempdir()
  expect_error(db_migrations(scripts), "No migration scripts")

  writeLines("SELECT 1;", file.path(scripts, "001_one.sql"))
  writeLines("SELECT 1;", file.path(scripts, "003_three.sql"))
  expect_error(db_migrations(scripts), "no gaps")
})


test_that("sql_statements splits a script and drops comments", {

  script <- withr::local_tempfile(fileext = ".sql")
  writeLines(con = script, c(
    "-- a comment; with a semicolon",
    "CREATE TABLE t (",
    "  x INTEGER",
    ");   ",
    "",
    "  -- indented comment",
    "INSERT INTO t VALUES (1);",
    "INSERT INTO t",
    "  VALUES (2)" ))

  expect_identical(
    sql_statements(script),
    c("CREATE TABLE t (\n  x INTEGER\n)",
      "INSERT INTO t VALUES (1)",
      "INSERT INTO t\n  VALUES (2)") )
})


# Transactions ----------------------------------------------------------------

test_that("db_transaction commits when the code finishes", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  value <- db_transaction(DB, {
    add_test_user(DB, "Ada Lovelace")
    add_test_user(DB, "Charles Babbage")
    "done"
  })

  expect_identical(value, "done")
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM users", "Test1"), 2L)

  # The transaction is over: a second connection can see the rows.
  other <- DBI::dbConnect(RSQLite::SQLite(), file.path(REQ$CONFIG$data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(other))
  expect_identical(DBI::dbGetQuery(other, "SELECT COUNT(*) FROM users")[[1]], 2L)
})


test_that("db_transaction rolls everything back on an error", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  add_test_user(DB, "Already here")

  expect_error(
    db_transaction(DB, {
      add_test_user(DB, "Ada Lovelace")
      db_query(DB, "UPDATE users SET full_name = 'Changed'", "Test1")
      stop("something went wrong")
    }),
    "something went wrong" )

  expect_identical(db_query(DB, "SELECT full_name FROM users", "Test2"), "Already here")

  # The connection is usable afterwards, and not stuck in a transaction.
  expect_no_error(db_transaction(DB, add_test_user(DB, "Charles Babbage")))
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM users", "Test3"), 2L)
})


test_that("db_transaction rolls back when a statement itself fails", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  expect_error(
    db_transaction(DB, {
      user <- add_test_user(DB, "Ada Lovelace")
      db_insert(DB, "permissions", "Test1", user_id = user, project_id = 12345L)
    }),
    class = "atima_db_error" )

  expect_null(db_query(DB, "SELECT user_id FROM users", "Test2"))
})


test_that("nested transactions roll back independently", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  names_in_db <- function () sort(db_query(DB, "SELECT full_name FROM users", "Test1", simplify = FALSE)[[1]])

  # An inner failure that is handled undoes only the inner changes.
  db_transaction(DB, {
    add_test_user(DB, "Outer")
    try(silent = TRUE, db_transaction(DB, {
      add_test_user(DB, "Inner")
      stop("inner failure")
    }))
    add_test_user(DB, "Outer again")
  })
  expect_identical(names_in_db(), c("Outer", "Outer again"))

  # An outer failure undoes inner transactions that had finished.
  expect_error(
    db_transaction(DB, {
      db_transaction(DB, add_test_user(DB, "Inner, finished"))
      stop("outer failure")
    }),
    "outer failure" )
  expect_identical(names_in_db(), c("Outer", "Outer again"))
})


# Queries ---------------------------------------------------------------------

test_that("db_query only runs allowed SQL verbs", {

  DB <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  on.exit(DBI::dbDisconnect(DB), add = TRUE)
  DBI::dbExecute(DB, "CREATE TABLE t (x INTEGER)")

  for (sql in c(
      "DROP TABLE t", "ALTER TABLE t ADD COLUMN y", "PRAGMA writable_schema = 1",
      "ATTACH DATABASE ':memory:' AS other", "CREATE TABLE u (x)", "VACUUM",
      "REPLACE INTO t VALUES (1)", "WITH a AS (SELECT 1) SELECT * FROM a",
      "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT s" )) {
    err <- expect_error(db_query(DB, sql, "Test1"), class = "atima_db_error", info = sql)
    expect_match(err$detail, "Invalid SQL verb", info = sql)
  }

  expect_identical(DBI::dbListTables(DB), "t")

  expect_identical(db_query(DB, "INSERT INTO t VALUES (?)", "Test2", list(1L)), 1L)
  expect_no_error(db_query(DB, "  insert into t values (?)", "Test3", list(2L)))
  expect_identical(db_query(DB, "UPDATE t SET x = 3", "Test4"), 2L)
  expect_identical(db_query(DB, "SELECT x FROM t", "Test5"), c(3L, 3L))
  expect_identical(db_query(DB, "DELETE FROM t", "Test6"), 2L)
  expect_null(db_query(DB, "SELECT x FROM t", "Test7"))
})


test_that("a failed query does not put SQL or parameters in its message", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  err <- expect_error(
    db_query(DB, "SELECT secret_column FROM users WHERE email = ?", "Leak1", list("ada@example.org")),
    class = "atima_db_error" )

  expect_identical(conditionMessage(err), "Database error (Leak1).")
  expect_no_match(conditionMessage(err), "secret_column|users|ada@example.org")

  # The details travel with the condition, for the server log.
  expect_identical(err$err_code, "Leak1")
  expect_match(err$sql, "SELECT secret_column FROM users")
  expect_identical(err$params, list("ada@example.org"))
  expect_match(err$detail, "secret_column")
})


test_that("db_query simplifies results and enforces req1", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  ada <- add_test_user(DB, "Ada Lovelace")
  add_test_user(DB, "Guest 2", is_guest = TRUE)

  expect_identical(db_query(DB, "SELECT full_name FROM users WHERE user_id = ?", "T1", list(ada)), "Ada Lovelace")
  expect_identical(
    db_query(DB, "SELECT full_name, is_guest FROM users WHERE user_id = ?", "T2", list(ada)),
    list(full_name = "Ada Lovelace", is_guest = FALSE) )
  expect_s3_class(db_query(DB, "SELECT full_name, is_guest FROM users", "T3"), "data.frame")
  expect_s3_class(db_query(DB, "SELECT full_name FROM users WHERE user_id = ?", "T4", list(ada), simplify = FALSE), "data.frame")

  expect_error(db_query(DB, "SELECT * FROM users", "T5", req1 = TRUE), class = "atima_db_error")
  expect_error(db_query(DB, "SELECT * FROM users WHERE user_id = 0", "T6", req1 = TRUE), class = "atima_db_error")
  expect_no_error(db_query(DB, "SELECT * FROM users WHERE user_id = ?", "T7", list(ada), req1 = TRUE))
})


test_that("db_update changes one existing row", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  ada <- add_test_user(DB, "Ada Lovelace")

  db_update(DB, "users", ada, "T1", affiliation = "Analytical Engines", email = NULL)
  expect_identical(
    db_query(DB, "SELECT affiliation, email FROM users WHERE user_id = ?", "T2", list(ada)),
    list(affiliation = "Analytical Engines", email = NA_character_) )

  err <- expect_error(db_update(DB, "users", 999L, "T3", full_name = "Nobody"), class = "atima_http_error")
  expect_identical(err$status, 400L)
})


# First run -------------------------------------------------------------------

test_that("a new database is seeded with public example projects", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req()
  DB  <- REQ$DB

  db_seed(DB, REQ$CONFIG)

  projects <- db_query(DB, "SELECT access_key, public_key, n_samples FROM projects ORDER BY project_id", "T1")
  expect_identical(projects$public_key, c("hmp50", "gems"))
  expect_match(projects$access_key, "^[a-z0-9]{12}$")
  expect_true(all(projects$n_samples > 0))

  # Public projects belong to nobody.
  expect_null(db_query(DB, "SELECT user_id FROM users", "T2"))
  expect_null(db_query(DB, "SELECT user_id FROM permissions", "T3"))
  expect_false(db_is_empty(DB))

  files <- db_query(DB, "SELECT file FROM biom_files", "T4")
  expect_true(all(file.exists(file.path(REQ$CONFIG$data_dir, "files", files))))
})


test_that("a time is stored as text, and a row read from the database can be written back", {

  # Found in the browser (step 7): db_query() returns `*_utc` columns as
  # times, and a time bound to a statement was stored as a number.
  REQ <- local_test_req()
  DB  <- REQ$DB

  user <- add_test_user(DB, "Ada")
  when <- as.POSIXct("2026-01-02 03:04:05", tz = "UTC")
  db_query(DB, "UPDATE users SET seen_utc = ? WHERE user_id = ?", "T1", list(when, user))

  stored <- DBI::dbGetQuery(DB, "SELECT typeof(seen_utc) AS type, seen_utc FROM users")
  expect_identical(stored$type, "text")
  expect_identical(stored$seen_utc, "2026-01-02 03:04:05")

  # Read it, write what was read, read it again.
  row <- db_query(DB, "SELECT * FROM users WHERE user_id = ?", "T2", list(user))
  expect_s3_class(row$seen_utc, "POSIXct")
  db_update(DB, "users", user, "T3", seen_utc = row$seen_utc)
  expect_identical(db_query(DB, "SELECT seen_utc FROM users WHERE user_id = ?", "T4", list(user)), when)
})


test_that("the upgrade to version 5 repairs creation dates that were stored as numbers", {

  data_dir <- withr::local_tempdir(pattern = "atima_v4_")
  DB       <- DBI::dbConnect(RSQLite::SQLite(), file.path(data_dir, "sqlite.db"))
  withr::defer(DBI::dbDisconnect(DB))

  db_migrate(DB, data_dir, db_migrations()[1:4, ])
  expect_identical(db_version(DB), 4L)

  run <- function (sql) DBI::dbExecute(DB, sql)
  run("INSERT INTO biom_files (biom_file_id, file, hash) VALUES (1, 'a.biom', 'a')")
  run("INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, created_utc) VALUES (1, 'Original', 1, 1, 1, 'aaaaaaaaaaaa', '2026-11-12 22:22:19')")
  run("INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, created_utc) VALUES (2, 'Copy', 1, 1, 1, 'bbbbbbbbbbbb', 1794520213)")

  db_migrate(DB, data_dir)
  expect_identical(db_version(DB), latest_version())

  dates <- DBI::dbGetQuery(DB, "SELECT typeof(created_utc) AS type, created_utc FROM projects ORDER BY project_id")
  expect_identical(dates$type, c("text", "text"))
  expect_identical(dates$created_utc, c("2026-11-12 22:22:19", "2026-11-12 21:50:13"))

  # The query that failed reads them now.
  expect_s3_class(db_query(DB, "SELECT created_utc FROM projects", "T1"), "POSIXct")
})
