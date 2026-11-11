# The cleanup rules, one test each, then all together.


sql_ago <- function (seconds) sql_time(Sys.time() - seconds)

count <- function (DB, table) DBI::dbGetQuery(DB, sprintf("SELECT COUNT(*) FROM %s", table))[[1]]

# A file with the given age in seconds.
aged_file <- function (path, age = 0) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines("x", path)
  Sys.setFileTime(path, Sys.time() - age)
  path
}

hour <- 3600
day  <- 86400


test_that("rule 1: signed-out and expired sessions are deleted", {

  REQ     <- local_test_req()
  DB      <- REQ$DB
  user    <- add_test_user(DB, "Ada")
  project <- add_test_project(DB, user)$project_id

  live    <- add_test_session(DB, user, project)
  quiet   <- add_test_session(DB, user, project)
  expired <- add_test_session(DB, user, project)
  left    <- add_test_session(DB, user, project)

  set <- function (session, sql, ...) db_query(DB, paste("UPDATE sessions SET", sql, "WHERE session_id = ?"), "T1", list(..., session$session_id))
  set(quiet,   "heartbeat_utc = ?", sql_ago(23 * hour))
  set(expired, "heartbeat_utc = ?", sql_ago(25 * hour))
  set(left,    "logout_utc = CURRENT_TIMESTAMP")

  expect_identical(cleanup_sessions(DB, Sys.time() - 24 * hour), 2L)

  expect_setequal(
    db_query(DB, "SELECT session_id FROM sessions", "T2"),
    c(live$session_id, quiet$session_id) )
})


test_that("loading a session keeps it and its user alive", {

  REQ     <- local_test_req()
  DB      <- REQ$DB
  user    <- add_test_user(DB, "Guest 1", is_guest = TRUE)
  project <- add_test_project(DB, user)$project_id
  session <- add_test_session(DB, user, project)

  db_query(DB, "UPDATE sessions SET heartbeat_utc = ?", "T1", list(sql_ago(20 * hour)))
  db_query(DB, "UPDATE users SET seen_utc = ?", "T2", list(sql_ago(20 * day)))

  resp <- handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), test_app(REQ))
  expect_identical(resp$status, 200L)

  recent <- function (time) as.numeric(difftime(Sys.time(), time, units = "secs")) < 60
  expect_true(recent(db_query(DB, "SELECT heartbeat_utc FROM sessions", "T3")))
  expect_true(recent(db_query(DB, "SELECT seen_utc FROM users", "T4")))
})


test_that("rule 2: drafts that no session has open are deleted", {

  REQ     <- local_test_req()
  DB      <- REQ$DB
  user    <- add_test_user(DB, "Ada")
  project <- add_test_project(DB, user)$project_id

  session <- add_test_session(DB, user, project)
  open    <- db_query(DB, "SELECT draft_id FROM sessions WHERE session_id = ?", "T1", list(session$session_id))

  # Two drafts left behind by switching projects.
  create_draft(DB, project)
  create_draft(DB, project)

  expect_identical(cleanup_drafts(DB), 2L)
  expect_identical(db_query(DB, "SELECT draft_id FROM drafts", "T2"), open)
})


test_that("rule 3: guests who have not returned are deleted, with what was theirs", {

  REQ <- local_test_req()
  DB  <- REQ$DB

  guest <- function (name, seen_days_ago) {
    id <- add_test_user(DB, name, is_guest = TRUE)
    db_query(DB, "UPDATE users SET seen_utc = ? WHERE user_id = ?", "T1", list(sql_ago(seen_days_ago * day), id))
    id
  }

  recent  <- guest("Guest recent", 29)
  stale   <- guest("Guest stale",  31)
  active  <- guest("Guest active", 31)
  member  <- add_test_user(DB, "Member")
  db_query(DB, "UPDATE users SET seen_utc = ? WHERE user_id = ?", "T2", list(sql_ago(400 * day), member))

  project <- add_test_project(DB, stale)$project_id
  create_collection(DB, stale, NULL, "Stale guest's folder")
  db_insert(DB, "auth_tokens", "T3", user_id = stale, auth_token_sha = "sha-of-stale")

  # A guest with a live session is kept, however long ago they were "seen".
  add_test_session(DB, active, add_test_project(DB, active)$project_id)

  expect_identical(cleanup_guests(DB, Sys.time() - 30 * day), 1L)

  expect_setequal(db_query(DB, "SELECT user_id FROM users", "T4"), c(recent, active, member))
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM permissions WHERE project_id = ?", "T5", list(project)), 0L)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM collections", "T6"), 0L)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM auth_tokens WHERE user_id = ?", "T7", list(stale)), 0L)
})


test_that("rule 4: private projects in nobody's tree are deleted", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  ada <- add_test_user(DB, "Ada")

  owned   <- add_test_project(DB, ada)$project_id
  public  <- add_test_project(DB, NULL, is_public = TRUE)$project_id
  orphan  <- add_test_project(DB, NULL)$project_id
  left    <- add_test_project(DB, ada)

  # "Delete project" in the tree removes the user's permission.
  db_query(DB, "DELETE FROM permissions WHERE permission_id = ?", "T1", list(left$permission_id))

  session <- add_test_session(DB, ada, orphan)

  expect_identical(cleanup_projects(DB), 2L)
  expect_setequal(db_query(DB, "SELECT project_id FROM projects", "T2"), c(owned, public))

  # Its drafts went with it, and a session that had it open has none now.
  expect_identical(count(DB, "drafts"), 0L)
  expect_true(is.na(db_query(DB, "SELECT draft_id FROM sessions WHERE session_id = ?", "T3", list(session$session_id))))
})


test_that("rule 5: file rows that nothing refers to are deleted", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  ada <- add_test_user(DB, "Ada")

  project <- add_test_project(DB, ada)$project_id
  in_use  <- db_query(DB, "SELECT orig_bf_id FROM projects WHERE project_id = ?", "T1", list(project))

  # A draft that points at a file of its own (a new rarefaction, say).
  in_draft <- add_test_biom_file(DB)
  session  <- add_test_session(DB, ada, project)
  db_query(DB, "UPDATE drafts SET rare_bf_id = ?", "T2", list(in_draft))

  add_test_biom_file(DB)
  add_test_biom_file(DB)

  expect_identical(cleanup_biom_files(DB), 2L)
  expect_setequal(db_query(DB, "SELECT biom_file_id FROM biom_files", "T3"), c(in_use, in_draft))
})


test_that("rule 6: stored files with no row are deleted once they are old", {

  REQ       <- local_test_req()
  DB        <- REQ$DB
  files_dir <- file.path(REQ$CONFIG$data_dir, "files")

  known <- db_query(DB, "SELECT file FROM biom_files WHERE biom_file_id = ?", "T1", list(add_test_biom_file(DB)))

  aged_file(file.path(files_dir, known),                   age = 10 * day)
  aged_file(file.path(files_dir, "abandoned.biom"),        age = 25 * hour)
  aged_file(file.path(files_dir, "abandoned.biom.1.x.tmp"), age = 25 * hour)
  aged_file(file.path(files_dir, "just-written.biom"),     age = 60)

  expect_identical(cleanup_stored_files(DB, REQ$CONFIG, Sys.time() - 24 * hour), 2L)
  expect_setequal(list.files(files_dir), c(known, "just-written.biom"))
})


test_that("rule 7: old temporary files are deleted, live sessions' recent ones are not", {

  REQ      <- local_test_req()
  DB       <- REQ$DB
  temp_dir <- REQ$CONFIG$temp_dir
  ada      <- add_test_user(DB, "Ada")
  session  <- add_test_session(DB, ada, add_test_project(DB, ada)$project_id)

  temp <- function (...) file.path(temp_dir, ...)

  kept <- c(
    aged_file(temp(session$session_key, "plot_recent.png"),        age = 23 * hour),
    aged_file(temp(session$session_key, "12", "metadata_12.csv"),  age = 2 * hour),
    aged_file(temp("downloads", "download_new.json"),              age = 60),
    aged_file(temp("upload_in_progress"),                          age = 60) )

  gone <- c(
    aged_file(temp(session$session_key, "plot_old.png"),           age = 25 * hour),
    aged_file(temp(session$session_key, "9", "taxa_9.csv"),        age = 25 * hour),
    aged_file(temp("deadSessionKey", "plot_any.png"),              age = 2 * hour),
    aged_file(temp("deadSessionKey", "3", "export.csv"),           age = 2 * hour),
    aged_file(temp("downloads", "download_old.json"),              age = 2 * hour),
    aged_file(temp("stray_upload"),                                age = 2 * hour) )

  n <- cleanup_temp(DB, REQ$CONFIG, session_cutoff = Sys.time() - 24 * hour, other_cutoff = Sys.time() - hour)

  expect_identical(n, length(gone))
  expect_true(all(file.exists(kept)))
  expect_false(any(file.exists(gone)))

  # Emptied directories are removed; ones still in use are not.
  expect_false(dir.exists(temp("deadSessionKey")))
  expect_false(dir.exists(temp(session$session_key, "9")))
  expect_true(dir.exists(temp(session$session_key, "12")))
  expect_true(dir.exists(temp("downloads")))
})


test_that("temporary file cleanup refuses to run inside the data directory", {

  REQ <- local_test_req()

  expect_true(dirs_overlap(REQ$CONFIG$data_dir, REQ$CONFIG$data_dir))
  expect_true(dirs_overlap(file.path(REQ$CONFIG$data_dir, "tmp"), REQ$CONFIG$data_dir))
  expect_true(dirs_overlap(dirname(REQ$CONFIG$data_dir), REQ$CONFIG$data_dir))
  expect_false(dirs_overlap(REQ$CONFIG$temp_dir, REQ$CONFIG$data_dir))
  expect_false(dirs_overlap(paste0(REQ$CONFIG$data_dir, "-other"), REQ$CONFIG$data_dir))

  config          <- REQ$CONFIG
  config$temp_dir <- config$data_dir
  old             <- aged_file(file.path(config$data_dir, "files", "precious.biom"), age = 10 * day)

  expect_identical(cleanup_temp(REQ$DB, config, Sys.time() - hour, Sys.time() - hour), 0L)
  expect_true(file.exists(old))
  expect_true(file.exists(file.path(config$data_dir, "sqlite.db")))

  expect_error(run(data_dir = config$data_dir, temp_dir = file.path(config$data_dir, "tmp"), open = FALSE), "temp_dir must not")
})


test_that("a full cleanup removes an expired guest's upload and keeps everything in use", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req()
  DB  <- REQ$DB
  app <- test_app(REQ)
  db_seed(DB, REQ$CONFIG)

  files_dir <- file.path(REQ$CONFIG$data_dir, "files")
  post      <- function (session, path, args) handle_request(fake_request("POST", path, args, session), app)

  # A guest opens the default project, rarefies it (an unsaved draft with a
  # file of its own), and uploads a project.
  resp    <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  session <- list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )

  upload <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(rbiom::rarefy(rbiom::hmp50, depth = 1500), upload)
  form   <- multipart_body(list(biom_file = list(filename = "mine.biom", value = read_file_raw(upload))))
  resp   <- handle_request(fake_request("POST", "/api/project/upload", form$body, session, content_type = form$content_type), app)
  expect_identical(resp$status, 200L)
  expect_identical(post(session, "/api/project/rarefy", list(depth = 1000))$status, 200L)

  seeded_files <- db_query(DB, "SELECT file FROM biom_files JOIN projects ON biom_file_id IN (orig_bf_id, full_bf_id, rare_bf_id) WHERE public_key IS NOT NULL", "T1")

  # Right away, nothing that is in use is removed: only the draft the
  # session left when it switched to its upload.
  removed <- cleanup_run(DB, REQ$CONFIG)
  expect_identical(removed$sessions, 0L)
  expect_identical(removed$guests,   0L)
  expect_identical(removed$projects, 0L)
  expect_identical(removed$stored_files, 0L)
  expect_identical(count(DB, "projects"), 3L)
  expect_identical(post(session, "/api/session/heartbeat", list())$status, 200L)

  # Two days later the session has expired: it, its draft and its temporary
  # files go, but the guest and the uploaded project stay.
  removed <- cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 2 * day)
  expect_identical(removed$sessions, 1L)
  expect_identical(removed$drafts,   1L)
  expect_identical(removed$guests,   0L)
  expect_identical(removed$projects, 0L)
  expect_gte(removed$biom_files, 1L)
  expect_gte(removed$stored_files, 1L)
  expect_identical(count(DB, "users"), 1L)
  expect_identical(count(DB, "projects"), 3L)
  expect_false(dir.exists(file.path(REQ$CONFIG$temp_dir, session$session_key)))
  expect_identical(post(session, "/api/session/heartbeat", list())$status, 401L)

  # Forty days later the guest is forgotten, and the upload with them.
  removed <- cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 40 * day)
  expect_identical(removed$guests,   1L)
  expect_identical(removed$projects, 1L)
  expect_identical(count(DB, "users"), 0L)
  expect_identical(count(DB, "permissions"), 0L)

  # What is left is exactly the two public example projects and their files.
  expect_setequal(db_query(DB, "SELECT public_key FROM projects", "T2"), c("hmp50", "gems"))
  expect_setequal(db_query(DB, "SELECT file FROM biom_files", "T3"), seeded_files)
  expect_setequal(list.files(files_dir), seeded_files)
  expect_identical(nrow(DBI::dbGetQuery(DB, "PRAGMA foreign_key_check")), 0L)

  # A second run finds nothing more to do.
  expect_equal(sum(unlist(cleanup_run(DB, REQ$CONFIG, now = Sys.time() + 40 * day))), 0)
})


test_that("the cleanup timer runs at once, repeats, and stops", {

  REQ  <- local_test_req()
  runs <- 0L
  local_mocked_bindings(cleanup_run = function (...) { runs <<- runs + 1L; if (runs == 2L) stop("one bad run") })

  stop_cleanup <- cleanup_start(test_app(REQ), interval = 0.05)
  expect_identical(runs, 1L)

  # It keeps going after a run that failed.
  expect_true(wait_until(function () runs >= 4L, seconds = 10))

  stop_cleanup()
  at_stop <- runs
  for (i in 1:10) later::run_now(timeoutSecs = 0.05)
  expect_identical(runs, at_stop)
})
