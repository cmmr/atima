# Importing projects from an older atima: the atima 2 adapter, the
# converter, the three routes, the limit on wrong passwords, and that the
# old password stays out of everything that is kept.

legacy_file <- local_legacy_file()

ada_login   <- function (app) list(source = app$source, email = "ada@example.org",   password = legacy_password("ada"))
grace_login <- function (app) list(source = app$source, email = "grace@example.org", password = legacy_password("grace"))

n_rows <- function (DB, table) DBI::dbGetQuery(DB, sprintf("SELECT COUNT(*) FROM %s", table))[[1]]

# The stored full dataset of a project, read back with rbiom.
project_biom <- function (REQ, project_id) {
  sql  <- "SELECT file FROM biom_files WHERE biom_file_id = (SELECT full_bf_id FROM projects WHERE project_id = ?)"
  file <- DBI::dbGetQuery(REQ$DB, sql, params = list(project_id))[[1]]
  rbiom::as_rbiom(file.path(REQ$CONFIG$data_dir, "files", file))
}

by_id <- function (projects) stats::setNames(projects, vapply(projects, function (p) p$id, character(1)))


# The converter ---------------------------------------------------------------

test_that("legacy_convert copies what an import needs and nothing else", {

  con <- legacy_open(legacy_file)
  withr::defer(DBI::dbDisconnect(con))

  expect_setequal(DBI::dbListTables(con), c("meta", "users", "projects", "permissions", "objects"))

  meta <- DBI::dbGetQuery(con, "SELECT * FROM meta")
  meta <- stats::setNames(meta$value, meta$key)
  expect_identical(meta[['format']], "atima2")
  expect_match(meta[['source_id']], "^[a-z0-9]{20}$")

  # Accounts with an email address, lower-cased; no names or affiliations.
  users <- DBI::dbGetQuery(con, "SELECT * FROM users ORDER BY user_id")
  expect_identical(users$email, c("ada@example.org", "grace@example.org", "dot@example.org"))
  expect_setequal(names(users), c("user_id", "email", "hashed_password", "user_key_salt", "private_key"))

  # Not the deleted project (15), and not the public one (14), which only
  # an account without an email address could edit.
  expect_identical(DBI::dbGetQuery(con, "SELECT project_id FROM projects ORDER BY 1")[[1]], c(11L, 12L, 13L, 16L, 17L))

  perms <- DBI::dbGetQuery(con, "SELECT user_id, project_id, is_editor FROM permissions ORDER BY project_id, user_id")
  expect_identical(perms$project_id, c(11L, 11L, 12L, 13L, 16L, 17L))
  expect_identical(perms$is_editor,  c(1L, 0L, 1L, 1L, 1L, 1L))

  # Only the objects an import uses, still encrypted.
  objects <- DBI::dbGetQuery(con, "SELECT DISTINCT object_name FROM objects")[[1]]
  expect_true(all(objects %in% atima2_objects))
  expect_false("OTU Counts" %in% objects)

  everything <- paste(unlist(lapply(DBI::dbListTables(con), function (t) unlist(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s", t))))), collapse = " ")
  expect_no_match(everything, "Example|Analytical Engines|Gut study|must not be copied")
})


test_that("legacy_convert refuses an existing file and a database that is not atima 2's", {

  other <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  withr::defer(DBI::dbDisconnect(other))

  expect_error(legacy_convert(other, legacy_file), "already exists")
  DBI::dbExecute(other, "CREATE TABLE things (id INTEGER)")

  file <- withr::local_tempfile(fileext = ".sqlite")
  expect_error(legacy_convert(other, file), "not an atima 2 database")
  expect_false(file.exists(file))
})


test_that("legacy_convert finds tables whatever the case of their names", {

  con <- local_atima2_db()
  for (table in c("Users", "Projects", "Objects", "Permissions"))
    DBI::dbExecute(con, sprintf("ALTER TABLE `%s` RENAME TO `%s_x`", table, tolower(table)))
  for (table in c("users", "projects", "objects", "permissions"))
    DBI::dbExecute(con, sprintf("ALTER TABLE `%s_x` RENAME TO `%s`", table, table))

  file <- withr::local_tempfile(fileext = ".sqlite")
  said <- paste(capture_messages(legacy_convert(con, file)), collapse = "")
  expect_match(said, "3 accounts, 5 projects")
})


# The setting -----------------------------------------------------------------

test_that("the legacy setting is read from a vector or from one string", {

  expect_identical(legacy_setting(NULL), character(0))
  expect_identical(legacy_setting(c("ATIMA 2" = "a.sqlite")), c("ATIMA 2" = "a.sqlite"))
  expect_identical(
    legacy_setting("ATIMA 2 = C:/data/a.sqlite ; Lab server=/srv/b.sqlite"),
    c("ATIMA 2" = "C:/data/a.sqlite", "Lab server" = "/srv/b.sqlite") )

  expect_error(legacy_setting("a.sqlite"), "label")
  expect_error(legacy_setting(c("a.sqlite", "b.sqlite")), "label")
  expect_error(legacy_setting(c(A = "a.sqlite", A = "b.sqlite")), "label")
  expect_error(legacy_setting(42), "character")
})


test_that("legacy files are checked when the server starts", {

  sources <- legacy_register(c("Old ATIMA" = legacy_file))
  expect_length(sources, 1)
  expect_identical(sources[[1]]$label, "Old ATIMA")
  expect_identical(sources[[1]]$format, "atima2")
  expect_identical(names(sources), sources[[1]]$id)

  expect_error(legacy_register(c(Gone = file.path(tempdir(), "no-such-file.sqlite"))), "does not exist")
  expect_error(legacy_register(c(One = legacy_file, Two = legacy_file)), "same conversion")

  not_one <- withr::local_tempfile(fileext = ".sqlite")
  writeLines("not a database", not_one)
  expect_error(legacy_register(c(Bad = not_one)), "legacy_convert")

  local_mocked_bindings(has_package = function (pkg) FALSE)
  expect_error(legacy_register(c("Old ATIMA" = legacy_file)), "needs the 'bcrypt' package")
})


# The atima 2 adapter ---------------------------------------------------------

test_that("an atima 2 user key is found however the old server decoded it", {

  # A hash whose last 31 characters are all in base64's alphabet, and one
  # with a '.' early on, for which the old decoder returned nothing.
  plain  <- paste0("$2a$04$", strrep("a", 22), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcde")
  dotted <- paste0("$2a$04$", strrep("a", 22), "ABCD.FGHIJKLMNOPQRSTUVWXYZabcde")

  keys <- atima2_user_keys(plain)
  expect_identical(keys[[1]], openssl::sha256(openssl::base64_decode("ABCDEFGHIJKLMNOPQRSTUVWXYZab")))
  expect_true(any(vapply(keys, identical, logical(1), openssl::sha256(raw(0)))))

  keys <- atima2_user_keys(dotted)
  expect_true(any(vapply(keys, identical, logical(1), openssl::sha256(raw(0)))))
  expect_true(any(vapply(keys, identical, logical(1), openssl::sha256(openssl::base64_decode("ABCD")))))

  expect_null(atima2_base64("ABC"))
  expect_null(atima2_base64("AB.D"))
  expect_identical(atima2_base64("QUJD"), charToRaw("ABC"))
})


test_that("the adapter verifies passwords and lists an account's projects", {

  con <- legacy_open(legacy_file)
  withr::defer(DBI::dbDisconnect(con))

  expect_null(atima2_verify(con, "ada@example.org", "not her password"))
  expect_null(atima2_verify(con, "ada@example.org", legacy_password("grace")))
  expect_null(atima2_verify(con, "nobody@example.org", legacy_password("ada")))

  ada <- atima2_verify(con, "ada@example.org", legacy_password("ada"))
  expect_identical(ada$user_id, 101L)

  projects <- atima2_projects(con, ada)
  expect_identical(vapply(projects, function (p) p$id, ""),    c("11", "12", "17"))
  expect_identical(vapply(projects, function (p) p$title, ""), c("Gut study", "Fractions", "Broken"))
  expect_true(all(vapply(projects, function (p) p$is_editor, NA)))

  grace <- atima2_projects(con, atima2_verify(con, "grace@example.org", legacy_password("grace")))
  grace <- by_id(grace)
  expect_setequal(names(grace), c("11", "13"))
  expect_false(grace[['11']]$is_editor)
  expect_true(grace[['13']]$is_editor)

  # The account whose user key is the SHA-256 of nothing.
  dot <- atima2_verify(con, "dot@example.org", legacy_password("dot"))
  expect_identical(vapply(atima2_projects(con, dot), function (p) p$title, ""), "Dot's")
})


test_that("a project is rebuilt with the metadata, taxonomy and tree atima 2 kept", {

  con <- legacy_open(legacy_file)
  withr::defer(DBI::dbDisconnect(con))

  ada      <- atima2_verify(con, "ada@example.org", legacy_password("ada"))
  projects <- by_id(atima2_projects(con, ada))
  dir      <- withr::local_tempdir()

  fetched <- atima2_fetch(con, projects[['11']], dir)

  expect_s3_class(fetched$biom, "rbiom")
  expect_identical(fetched$biom$n_samples, 50L)
  expect_identical(fetched$depth, 1200)
  expect_true(file.exists(fetched$file))

  # The column added after upload, and the dates as text.
  expect_true(all(c("Edited", "Collected", "Age", "Body Site") %in% fetched$biom$fields))
  expect_false("Sex" %in% fetched$biom$fields)
  expect_false(is.null(fetched$biom$tree))
  expect_identical(fetched$biom$ranks, rbiom::hmp50$ranks)

  # A file stored as text, and a tree placeholder (`NA`).
  fractions <- atima2_fetch(con, projects[['12']], dir)
  expect_identical(fractions$biom$n_samples, 50L)
  expect_null(fractions$depth)

  err <- expect_error(atima2_fetch(con, projects[['17']], dir), class = "atima_http_error")
  expect_match(conditionMessage(err), "damaged")
})


# The routes ------------------------------------------------------------------

test_that("the import routes are for people with an account", {

  app   <- local_legacy_app(legacy_file)
  guest <- app$sign_in("Guest", is_guest = TRUE)

  for (path in c("/api/legacy/sources", "/api/legacy/list", "/api/legacy/import")) {
    resp <- guest$post(path, c(ada_login(app), list(project = "11")))
    expect_identical(resp$status, 403L, info = path)
  }

  expect_identical(n_rows(app$DB, "legacy_attempts"), 0L)

  user    <- app$sign_in("Ada New")
  sources <- response_json(user$post("/api/legacy/sources"))$sources
  expect_identical(sources, list(list(id = app$source, label = "Old ATIMA")))

  resp <- user$post("/api/legacy/list", list(source = "nosuchsource", email = "ada@example.org", password = "x"))
  expect_identical(resp$status, 404L)
})


test_that("the session data says whether there is anything to import from", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  s    <- local_open_project()
  conf <- function () response_json(s$post("/api/session/init"))$CONF

  expect_false(conf()$legacy)
  s$REQ$CONFIG$legacy <- legacy_register(c("Old ATIMA" = legacy_file))
  s$app$config        <- s$REQ$CONFIG
  expect_true(response_json(handle_request(fake_request("POST", "/api/session/init", list()), s$app))$CONF$legacy)
})


test_that("the right password lists the old projects and the wrong one does not", {

  app  <- local_legacy_app(legacy_file)
  user <- app$sign_in("Ada New")

  resp <- user$post("/api/legacy/list", list(source = app$source, email = "ada@example.org", password = "wrong"))
  body <- response_json(resp)
  expect_identical(resp$status, 400L)
  expect_identical(body$error$code, "wrong_credentials")
  expect_match(body$error$message, "do not match an account in Old ATIMA")
  expect_match(body$error$message, "4 more times")

  # An address nobody registered is answered in the same words.
  resp <- user$post("/api/legacy/list", list(source = app$source, email = "nobody@example.org", password = "wrong"))
  expect_match(response_json(resp)$error$message, "do not match an account in Old ATIMA")

  # Upper case and spaces around the address do not matter.
  resp <- user$post("/api/legacy/list", list(source = app$source, email = "  ADA@example.org ", password = legacy_password("ada")))
  expect_identical(resp$status, 200L)

  projects <- by_id(response_json(resp)$projects)
  expect_identical(names(projects), c("11", "12", "17"))
  expect_identical(projects[['11']], list(id = "11", title = "Gut study", created = "2021-03-04", level = "editor", status = "new"))
})


test_that("a project is imported once, readable by rbiom, with its old level and date", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  app  <- local_legacy_app(legacy_file)
  ada  <- app$sign_in("Ada New")
  before <- n_rows(app$DB, "projects")

  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))
  body <- response_json(resp)

  expect_identical(resp$status, 200L)
  expect_identical(body$status, "imported")
  expect_identical(body$tree_node$text, "Gut study")
  expect_true(body$tree_node$editor)
  expect_identical(n_rows(app$DB, "projects"), before + 1L)

  record <- DBI::dbGetQuery(app$DB, "SELECT * FROM legacy_imports")
  expect_identical(record$source, app$source)
  expect_identical(record$old_project, "11")
  expect_identical(record$user_id, as.integer(ada$user_id))

  project <- DBI::dbGetQuery(app$DB, "SELECT * FROM projects WHERE project_id = ?", params = list(record$project_id))
  expect_identical(project$title, "Gut study")
  expect_identical(project$created_utc, "2021-03-04 05:06:07")
  expect_identical(project$n_samples, 50L)
  expect_match(project$access_key, "^[a-z0-9]{12}$")

  biom <- project_biom(app$REQ, record$project_id)
  expect_identical(biom$n_samples, 50L)
  expect_true("Edited" %in% biom$fields)
  expect_false(is.null(biom$tree))

  # The depth atima 2 had the project at.
  sql  <- "SELECT file FROM biom_files WHERE biom_file_id = (SELECT rare_bf_id FROM projects WHERE project_id = ?)"
  rare <- rbiom::as_rbiom(file.path(app$REQ$CONFIG$data_dir, "files", DBI::dbGetQuery(app$DB, sql, params = list(record$project_id))[[1]]))
  expect_true(all(rbiom::sample_sums(rare) == 1200))

  # Again: no second project.
  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))
  expect_identical(response_json(resp)$status, "have")
  expect_identical(n_rows(app$DB, "projects"), before + 1L)
  expect_identical(n_rows(app$DB, "legacy_imports"), 1L)

  listed <- by_id(response_json(ada$post("/api/legacy/list", ada_login(app)))$projects)
  expect_identical(listed[['11']]$status, "have")
  expect_identical(listed[['12']]$status, "new")

  # A project that is not hers, and one that does not exist.
  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "13")))
  expect_identical(resp$status, 404L)
  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "999")))
  expect_identical(resp$status, 404L)
  expect_identical(n_rows(app$DB, "legacy_attempts"), 0L)
})


test_that("someone else who could open the old project is added to the same one", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  app   <- local_legacy_app(legacy_file)
  ada   <- app$sign_in("Ada New")
  grace <- app$sign_in("Grace New")

  ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))
  project_id <- DBI::dbGetQuery(app$DB, "SELECT project_id FROM legacy_imports")[[1]]
  before     <- n_rows(app$DB, "projects")

  listed <- by_id(response_json(grace$post("/api/legacy/list", grace_login(app)))$projects)
  expect_identical(listed[['11']]$status, "shared")
  expect_identical(listed[['11']]$level, "viewer")

  resp <- grace$post("/api/legacy/import", c(grace_login(app), list(project = "11")))
  body <- response_json(resp)
  expect_identical(body$status, "added")
  expect_false(body$tree_node$editor)
  expect_identical(n_rows(app$DB, "projects"), before)

  perms <- DBI::dbGetQuery(app$DB, "SELECT user_id, is_editor FROM permissions WHERE project_id = ? ORDER BY user_id", params = list(project_id))
  expect_identical(perms$user_id,   as.integer(c(ada$user_id, grace$user_id)))
  expect_identical(perms$is_editor, c(1L, 0L))
})


test_that("a viewer who imports first can only view, and the editor gets it back as editor", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  app   <- local_legacy_app(legacy_file)
  ada   <- app$sign_in("Ada New")
  grace <- app$sign_in("Grace New")

  body <- response_json(grace$post("/api/legacy/import", c(grace_login(app), list(project = "11"))))
  expect_identical(body$status, "imported")
  expect_false(body$tree_node$editor)
  expect_identical(body$tree_node$info$editors, list())

  body <- response_json(ada$post("/api/legacy/import", c(ada_login(app), list(project = "11"))))
  expect_identical(body$status, "added")
  expect_true(body$tree_node$editor)
  expect_identical(n_rows(app$DB, "legacy_imports"), 1L)
})


test_that("counts that are not whole numbers are asked about, as for an upload", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  app <- local_legacy_app(legacy_file)
  ada <- app$sign_in("Ada New")

  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "12")))
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error$code, "confirm_inflate")
  expect_identical(n_rows(app$DB, "legacy_imports"), 0L)

  # The password was right, so this did not count as an attempt.
  expect_identical(n_rows(app$DB, "legacy_attempts"), 0L)

  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "12", inflate = TRUE)))
  expect_identical(response_json(resp)$status, "imported")
})


test_that("a damaged project is refused with a message and costs no attempt", {

  app  <- local_legacy_app(legacy_file)
  ada  <- app$sign_in("Ada New")
  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "17")))

  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "damaged")
  expect_identical(n_rows(app$DB, "legacy_attempts"), 0L)
  expect_identical(n_rows(app$DB, "legacy_imports"), 0L)
})


# The limit on wrong passwords ------------------------------------------------

test_that("five wrong passwords lock the person out for a while", {

  app  <- local_legacy_app(legacy_file)
  ada  <- app$sign_in("Ada New")
  wrong <- list(source = app$source, email = "ada@example.org", password = "a guess")

  for (i in 1:5) expect_identical(ada$post("/api/legacy/list", wrong)$status, 400L)

  expect_match(response_json(ada$post("/api/legacy/list", wrong))$error$message, "Too many wrong passwords")

  # Even the right password, and a different old account, must wait.
  resp <- ada$post("/api/legacy/list", ada_login(app))
  expect_identical(resp$status, 429L)
  expect_match(response_json(resp)$error$message, "wait 1[45] minutes")
  expect_identical(ada$post("/api/legacy/list", grace_login(app))$status, 429L)
  expect_identical(ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))$status, 429L)

  # Refused requests are not counted on top.
  expect_identical(n_rows(app$DB, "legacy_attempts"), 10L)

  # The old account is locked for everyone, whoever asks.
  other <- app$sign_in("Someone Else")
  expect_identical(other$post("/api/legacy/list", ada_login(app))$status, 429L)
  expect_identical(other$post("/api/legacy/list", grace_login(app))$status, 200L)

  # Fifteen minutes later.
  DBI::dbExecute(app$DB, "UPDATE legacy_attempts SET attempt_utc = datetime('now', '-16 minutes')")
  expect_identical(ada$post("/api/legacy/list", ada_login(app))$status, 200L)
})


test_that("a right password is not counted, and old counts are forgotten", {

  app <- local_legacy_app(legacy_file)
  ada <- app$sign_in("Ada New")

  for (i in 1:4)
    ada$post("/api/legacy/list", list(source = app$source, email = "ada@example.org", password = "a guess"))

  expect_identical(n_rows(app$DB, "legacy_attempts"), 8L)

  for (i in 1:3) expect_identical(ada$post("/api/legacy/list", ada_login(app))$status, 200L)
  expect_identical(n_rows(app$DB, "legacy_attempts"), 8L)

  # No email address is kept, only a hash of it.
  subjects <- DBI::dbGetQuery(app$DB, "SELECT DISTINCT subject FROM legacy_attempts")[[1]]
  expect_true(all(grepl("^(user:[0-9]+|account:[0-9a-f]{64})$", subjects)))

  DBI::dbExecute(app$DB, "UPDATE legacy_attempts SET attempt_utc = datetime('now', '-2 days')")
  ada$post("/api/legacy/list", ada_login(app))
  expect_identical(n_rows(app$DB, "legacy_attempts"), 0L)
})


# Secrets ---------------------------------------------------------------------

test_that("a secret does not print, deparse or convert to text", {

  s <- secret("hunter2-old-password")

  expect_identical(reveal(s), "hunter2-old-password")
  expect_no_match(paste(capture.output(print(s)), collapse = " "), "hunter2")
  expect_no_match(paste(deparse(s), collapse = " "), "hunter2")
  expect_no_match(paste(deparse(list(password = s)), collapse = " "), "hunter2")
  expect_no_match(paste(format_calls(list(as.call(list(as.name("f"), password = s)))), collapse = " "), "hunter2")
  expect_error(reveal("hunter2-old-password"))

  spec <- arg_secret(min = 1L, max = 20L)
  expect_s3_class(spec$check("abc"), "atima_secret")
  expect_identical(reveal(spec$check("  spaces kept  ")), "  spaces kept  ")
  expect_error(spec$check(""), "at least")
  err <- expect_error(spec$check(strrep("x", 21)), "at most")
  expect_no_match(conditionMessage(err), "xxxx")
})


test_that("nothing secret reaches the log, the database or a file", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  app  <- local_legacy_app(legacy_file)
  logs <- local_log()
  ada  <- app$sign_in("Ada New")

  ada$post("/api/legacy/list",   list(source = app$source, email = "ada@example.org", password = "a-wrong-guess-77"))
  ada$post("/api/legacy/list",   ada_login(app))
  ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))
  ada$post("/api/legacy/import", c(ada_login(app), list(project = "17")))

  # A failure inside the adapter: the account's private key is unreadable.
  broken <- withr::local_tempfile(fileext = ".sqlite")
  file.copy(legacy_file, broken)
  con <- DBI::dbConnect(RSQLite::SQLite(), broken)
  DBI::dbExecute(con, "UPDATE users SET private_key = 'bm90IGEga2V5' WHERE email = 'grace@example.org'")
  DBI::dbExecute(con, "UPDATE meta SET value = 'brokensource' WHERE key = 'source_id'")
  DBI::dbDisconnect(con)

  app$REQ$CONFIG$legacy <- c(app$REQ$CONFIG$legacy, legacy_register(c(Broken = broken)))

  # A 500 logs the call stack, which here starts in this test: keep the
  # values out of the call itself, as they are in a real request.
  args <- list(source = "brokensource", email = "grace@example.org", password = legacy_password("grace"))
  resp <- ada$post("/api/legacy/list", args)
  expect_identical(resp$status, 500L)
  expect_match(response_json(resp)$error$message, "could not be read")

  secrets <- c(legacy_password("ada"), legacy_password("grace"), "a-wrong-guess-77", "ada@example.org", "grace@example.org")
  absent  <- function (text, where) {
    for (s in secrets) expect_false(grepl(s, text, fixed = TRUE), info = paste(s, "in", where))
  }

  entries <- logs()
  expect_gt(length(entries), 5)
  expect_true(any(vapply(entries, function (e) identical(e$event, "legacy_import"), NA)))
  absent(paste(vapply(entries, function (e) as.character(jsonlite::toJSON(e, auto_unbox = TRUE)), ""), collapse = "\n"), "the log")

  for (table in DBI::dbListTables(app$DB))
    absent(paste(unlist(DBI::dbGetQuery(app$DB, sprintf("SELECT * FROM %s", table))), collapse = "\n"), paste("table", table))

  # Every file the server keeps or left behind, the database's among them.
  files <- list.files(c(app$REQ$CONFIG$data_dir, app$REQ$CONFIG$temp_dir), recursive = TRUE, full.names = TRUE)
  expect_true(any(grepl("sqlite.db", files, fixed = TRUE)))

  for (file in files) {
    bytes <- readBin(file, "raw", file.size(file))
    for (s in secrets)
      expect_length(grepRaw(charToRaw(s), bytes, fixed = TRUE), 0)
  }
})


# Through real worker processes -----------------------------------------------

test_that("an import runs in a worker process", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  pool <- local_test_pool(workers = 1L, time_limit = 60)
  app  <- local_legacy_app(legacy_file, pool = pool)
  ada  <- app$sign_in("Ada New")

  resp <- ada$post("/api/legacy/list", list(source = app$source, email = "ada@example.org", password = "wrong"))
  expect_identical(resp$status, 400L)

  resp <- ada$post("/api/legacy/import", c(ada_login(app), list(project = "11")))
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$status, "imported")
  expect_identical(project_biom(app$REQ, DBI::dbGetQuery(app$DB, "SELECT project_id FROM legacy_imports")[[1]])$n_samples, 50L)
})
