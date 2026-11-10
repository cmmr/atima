# Sessions, public projects and BIOM downloads, with real example data.


# A database seeded with rbiom's example projects, as on first run.
local_seeded_req <- function (env = parent.frame()) {
  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")
  REQ <- local_test_req(env)
  db_seed(REQ$DB, REQ$CONFIG)
  REQ
}

# The credentials a response from /api/session/init hands to the browser.
session_from <- function (resp) {
  list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )
}


test_that("a first visit opens the oldest public project as a guest", {

  REQ  <- local_seeded_req()
  app  <- test_app(REQ)

  resp <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  expect_identical(resp$status, 200L)

  body <- response_json(resp)
  expect_named(body, c("jstree_data", "BIOM", "CONF"))
  expect_true(body$CONF$is_guest)
  expect_false(body$CONF$is_admin)
  expect_null(body$CONF$migration_queue)

  expect_identical(body$BIOM$access_key, "hmp50")
  expect_true(body$BIOM$is_public)
  expect_false(body$BIOM$is_editor)

  # The public tree lists both example projects; the guest's own is empty.
  public <- body$jstree_data$public
  expect_setequal(vapply(public, function (n) n$info$access_key, ""), c("hmp50", "gems"))
  expect_true(all(grepl("^G[0-9]+$", vapply(public, function (n) n$id, ""))))
  expect_false(any(vapply(public, function (n) n$editor, NA)))
  expect_length(body$jstree_data$private, 0)
  expect_true(body$BIOM$node_id %in% vapply(public, function (n) n$id, ""))

  # Viewing a public project does not create a grant.
  expect_null(db_query(REQ$DB, "SELECT user_id FROM permissions", "T1"))

  # The cookie is sent back to every path, not just /api/session/.
  expect_match(resp$headers[['Set-Cookie']], "; Path=/(;|$)")
  expect_match(resp$headers[['Set-Cookie']], "HttpOnly")

  # The new session works for later requests.
  session <- session_from(resp)
  resp    <- handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), app)
  expect_identical(resp$status, 200L)
})


test_that("a session can be opened on a project by its access key", {

  REQ <- local_seeded_req()
  app <- test_app(REQ)

  body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = "gems")), app))
  expect_identical(body$BIOM$access_key, "gems")

  # An unknown or malformed key falls back to the default project.
  for (key in c("nosuchproject", "!!", "")) {
    body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = key)), app))
    expect_identical(body$BIOM$access_key, "hmp50", info = key)
  }
})


test_that("with no project to open, the session cannot start", {

  REQ  <- local_test_req()
  resp <- handle_request(fake_request("POST", "/api/session/init", list()), test_app(REQ))

  expect_identical(resp$status, 404L)

  # The failed attempt left no guest account behind.
  expect_null(db_query(REQ$DB, "SELECT user_id FROM users", "T1"))
})


test_that("the tree routes work on public and private nodes", {

  REQ <- local_seeded_req()
  app <- test_app(REQ)

  session <- session_from(handle_request(fake_request("POST", "/api/session/init", list()), app))
  post    <- function (path, args = list()) handle_request(fake_request("POST", path, args, session), app)

  gems <- db_query(REQ$DB, "SELECT project_id FROM projects WHERE access_key = 'gems'", "T1")

  # Select a public project by its node.
  resp <- post("/api/tree/select", list(node_id = paste0("G", gems)))
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$BIOM$access_key, "gems")

  # Make a collection, rename it, nest another inside, and move things.
  resp <- post("/api/tree/create", list(node_id = "#"))
  expect_identical(resp$status, 200L)
  outer <- response_json(resp)$node$id
  expect_match(outer, "^C[0-9]+$")

  expect_identical(post("/api/tree/rename", list(node_id = outer, text = "My studies"))$status, 200L)
  expect_identical(db_query(REQ$DB, "SELECT jstree_text FROM collections", "T2"), "My studies")

  inner <- response_json(post("/api/tree/create", list(node_id = outer)))$node$id
  expect_identical(post("/api/tree/move", list(node_id = outer, parent_node_id = inner))$status, 400L)
  expect_identical(post("/api/tree/move", list(node_id = inner, parent_node_id = "#"))$status, 200L)
  expect_identical(post("/api/tree/delete", list(node_id = inner))$status, 200L)

  # Public nodes cannot be renamed, moved or deleted through the tree.
  for (path in c("/api/tree/delete", "/api/tree/leave"))
    expect_identical(post(path, list(node_id = paste0("G", gems)))$status, 400L, info = path)

  # Another user's collection is off limits.
  other <- add_test_user(REQ$DB, "Someone Else")
  theirs <- paste0("C", create_collection(REQ$DB, other, NULL, "Their studies"))
  expect_identical(post("/api/tree/rename", list(node_id = theirs, text = "Hijacked"))$status, 403L)
  expect_identical(post("/api/tree/delete", list(node_id = theirs))$status, 403L)
  expect_identical(post("/api/tree/create", list(node_id = theirs))$status, 403L)
  expect_identical(post("/api/tree/move",   list(node_id = outer, parent_node_id = theirs))$status, 403L)
})


test_that("an administrator can publish and unpublish the open project", {

  REQ   <- local_seeded_req()
  DB    <- REQ$DB
  app   <- test_app(REQ)
  admin <- add_test_user(DB, "Adam Admin", is_admin = TRUE)
  user  <- add_test_user(DB, "Ursula User")

  hmp50   <- db_query(DB, "SELECT project_id FROM projects WHERE access_key = 'hmp50'", "T1")
  public  <- create_collection(DB, NULL, NULL, "Examples")
  private <- create_collection(DB, user, NULL, "Mine")

  is_public <- function () db_query(DB, "SELECT is_public, public_collection_id FROM projects WHERE project_id = ?", "T2", list(hmp50))
  post <- function (session, args) handle_request(fake_request("POST", "/api/project/publish", args, session), app)

  admin_session <- add_test_session(DB, admin, hmp50)
  user_session  <- add_test_session(DB, user,  hmp50)

  expect_identical(post(user_session, list(is_public = FALSE))$status, 403L)
  expect_true(is_public()$is_public)

  # A private collection is not a place in the public tree.
  expect_identical(post(admin_session, list(is_public = TRUE, collection_id = private))$status, 400L)

  resp <- post(admin_session, list(is_public = TRUE, collection_id = public))
  expect_identical(resp$status, 200L)
  expect_identical(is_public(), list(is_public = TRUE, public_collection_id = public))

  node <- Filter(function (n) identical(n$info$access_key, "hmp50"), response_json(resp)$jstree_data$public)[[1]]
  expect_identical(node$parent, paste0("C", public))
  expect_true(node$editor)

  # Unpublishing removes it from everyone's view, the administrator's included.
  expect_identical(post(admin_session, list(is_public = FALSE))$status, 200L)
  expect_identical(is_public(), list(is_public = FALSE, public_collection_id = NA_integer_))
  expect_identical(project_access(DB, hmp50, user),  "none")
  expect_identical(project_access(DB, hmp50, admin), "none")
})


test_that("BIOM files can be downloaded by access key", {

  REQ <- local_seeded_req()
  app <- test_app(REQ)

  resp <- handle_request(fake_request("GET", "/hmp50/rare.json"), app)
  expect_identical(resp$status, 200L)
  expect_match(resp$headers[['Content-Type']], "application/json")
  expect_identical(resp$headers[['Content-Disposition']], 'attachment; filename="rare.json"')
  expect_type(resp$body, "raw")

  # What comes back is the project, readable by rbiom.
  file <- withr::local_tempfile(fileext = ".json")
  writeBin(resp$body, file)
  biom <- rbiom::as_rbiom(file)
  expect_identical(biom$n_samples, rbiom::rarefy(rbiom::hmp50)$n_samples)

  # Other formats and compression.
  resp <- handle_request(fake_request("GET", "/hmp50/full.tab.gz"), app)
  expect_identical(resp$status, 200L)
  expect_identical(resp$headers[['Content-Type']], "application/gzip")
  expect_identical(resp$body[1:2], as.raw(c(0x1f, 0x8b)))

  expect_identical(handle_request(fake_request("GET", "/nosuchkey/rare.json"), app)$status, 404L)
  expect_identical(handle_request(fake_request("GET", "/hmp50/rare.exe"), app)$status, 400L)
})


test_that("a private project downloads with its key and not without", {

  REQ <- local_seeded_req()
  DB  <- REQ$DB
  app <- test_app(REQ)

  # Make the seeded project private; its access key still works as a link.
  db_query(DB, "UPDATE projects SET is_public = 0, access_key = 'Zx81PrivKey' WHERE access_key = 'gems'", "T1")

  expect_identical(handle_request(fake_request("GET", "/Zx81PrivKey/rare.json"), app)$status, 200L)
  expect_identical(handle_request(fake_request("GET", "/gems/rare.json"), app)$status, 404L)
})


test_that("the working copy of a session can be downloaded by its session key", {

  REQ <- local_seeded_req()
  DB  <- REQ$DB
  app <- test_app(REQ)

  session <- session_from(handle_request(fake_request("POST", "/api/session/init", list()), app))

  resp <- handle_request(fake_request("GET", paste0("/unsaved/", session$session_key, "/full.json")), app)
  expect_identical(resp$status, 200L)
  expect_type(resp$body, "raw")

  expect_identical(handle_request(fake_request("GET", "/unsaved/nosuchsession/full.json"), app)$status, 404L)

  # A session that has been signed out no longer serves its draft.
  db_query(DB, "UPDATE sessions SET logout_utc = CURRENT_TIMESTAMP", "T1")
  resp <- handle_request(fake_request("GET", paste0("/unsaved/", session$session_key, "/full.json")), app)
  expect_identical(resp$status, 404L)
})


test_that("is_project_readable and is_project_writable follow project_access", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Edith Editor")
  viewer <- add_test_user(DB, "Victor Viewer")
  admin  <- add_test_user(DB, "Adam Admin", is_admin = TRUE)
  guest  <- add_test_user(DB, "Guest 4", is_guest = TRUE)

  private <- add_test_project(DB, editor)$project_id
  public  <- add_test_project(DB, editor, is_public = TRUE)$project_id
  db_insert(DB, "permissions", "T1", user_id = viewer, project_id = private, is_editor = FALSE)
  key <- db_query(DB, "SELECT access_key FROM projects WHERE project_id = ?", "T2", list(private))

  expect_identical(project_access(DB, private, editor), "editor")
  expect_identical(project_access(DB, private, viewer), "viewer")
  expect_identical(project_access(DB, private, admin),  "none")
  expect_identical(project_access(DB, private, guest),  "none")
  expect_identical(project_access(DB, private, NULL),   "none")

  expect_identical(project_access(DB, public, editor), "editor")
  expect_identical(project_access(DB, public, viewer), "viewer")
  expect_identical(project_access(DB, public, admin),  "editor")
  expect_identical(project_access(DB, public, guest),  "viewer")
  expect_identical(project_access(DB, public, NULL),   "viewer")

  expect_identical(project_access(DB, 999L, editor), "none")
  expect_identical(project_access(DB, NA,   editor), "none")

  expect_true( is_project_readable(DB, private, viewer))
  expect_false(is_project_readable(DB, private, guest))
  expect_true( is_project_readable(DB, private, guest, access_key = key))
  expect_false(is_project_readable(DB, private, guest, access_key = "wrong-key"))
  expect_true( is_project_readable(DB, public,  NULL))

  expect_true( is_project_writable(DB, private, editor))
  expect_false(is_project_writable(DB, private, viewer))
  expect_true( is_project_writable(DB, public,  admin))
  expect_false(is_project_writable(DB, public,  guest))
})
