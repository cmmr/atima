# Sessions, public projects and BIOM downloads, with real example data.


# A database seeded with rbiom's example projects, as on first run.
local_seeded_req <- function (env = parent.frame(), ...) {
  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")
  REQ <- local_test_req(env, ...)
  db_seed(REQ$DB, REQ$CONFIG)
  REQ
}


test_that("a first visit opens the oldest public project as a guest", {

  REQ  <- local_seeded_req()
  app  <- test_app(REQ)

  resp <- handle_request(fake_request("POST", "/api/session/init", list()), app)
  expect_identical(resp$status, 200L)

  body <- response_json(resp)
  expect_named(body, c("tree", "BIOM", "CONF"))
  expect_identical(body$CONF$auth, "oidc")
  expect_true(body$CONF$is_guest)
  expect_false(body$CONF$is_admin)
  expect_match(body$CONF$full_name, "^Guest [0-9]+$")

  # A visitor knows a public project by its public key, never its private one.
  expect_identical(body$BIOM$public_key, "hmp50")
  expect_identical(body$BIOM$project_key, "hmp50")
  expect_null(body$BIOM$access_key)
  expect_true(body$BIOM$is_public)
  expect_false(body$BIOM$is_editor)

  # The public tree lists both example projects; the guest's own is empty.
  public <- body$tree$public
  expect_setequal(vapply(public, function (n) n$info$access_key, ""), c("hmp50", "gems"))
  expect_true(all(grepl("^G[0-9]+$", vapply(public, function (n) n$id, ""))))
  expect_false(any(vapply(public, function (n) n$editor, NA)))
  expect_length(body$tree$private, 0)
  expect_true(body$BIOM$node_id %in% vapply(public, function (n) n$id, ""))

  private_keys <- db_query(REQ$DB, "SELECT access_key FROM projects", "T0")
  expect_false(any(vapply(private_keys, grepl, NA, x = resp$body, fixed = TRUE)))

  # Viewing a public project does not create a grant.
  expect_null(db_query(REQ$DB, "SELECT user_id FROM permissions", "T1"))

  # The new session works for later requests.
  session <- session_from(resp)
  expect_match(session$session_key, "^[0-9]+[A-Za-z0-9]{24}$")
  resp    <- handle_request(fake_request("POST", "/api/session/heartbeat", list(), session), app)
  expect_identical(resp$status, 200L)
})


test_that("a session can be opened on a project by its public key", {

  REQ <- local_seeded_req()
  app <- test_app(REQ)

  body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = "gems")), app))
  expect_identical(body$BIOM$public_key, "gems")

  # An unknown or malformed key falls back to the default project.
  for (key in c("nosuchproject", "!!", "")) {
    body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = key)), app))
    expect_identical(body$BIOM$public_key, "hmp50", info = key)
  }
})


test_that("a private key is a share link that leaves a lasting view grant", {

  REQ   <- local_seeded_req()
  DB    <- REQ$DB
  app   <- test_app(REQ)
  owner <- add_test_user(DB, "Olga Owner")

  # Make one of the seeded projects private, owned by somebody.
  gems <- db_query(DB, "SELECT project_id, access_key, title FROM projects WHERE public_key = 'gems'", "T1")
  db_update(DB, "projects", gems$project_id, "T2", public_key = NULL)
  db_insert(DB, "permissions", "T3", user_id = owner, project_id = gems$project_id)

  # Its old public key no longer opens it.
  body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = "gems")), app))
  expect_identical(body$BIOM$public_key, "hmp50")

  # Its private key does, for anyone, and the visitor keeps the project.
  resp <- handle_request(fake_request("POST", "/api/session/init", list(access_key = gems$access_key)), app)
  body <- response_json(resp)
  expect_identical(body$BIOM$title, gems$title)
  expect_identical(body$BIOM$access_key, gems$access_key)
  expect_false(body$BIOM$is_public)
  expect_false(body$BIOM$is_editor)
  expect_length(body$tree$private, 1)

  guest <- body$CONF$user_id
  grant <- db_query(DB, "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?", "T4", list(guest, gems$project_id))
  expect_identical(grant, FALSE)

  # On the next visit, with no key in the URL, it is the project they see.
  again <- handle_request(fake_request("POST", "/api/session/init", list(), session_from(resp)), app)
  expect_identical(response_json(again)$BIOM$title, gems$title)
  expect_identical(response_json(again)$CONF$user_id, guest)

  # The owner's grant is untouched by their own link.
  session <- add_test_session(DB, owner, gems$project_id)
  body <- response_json(handle_request(fake_request("POST", "/api/session/init", list(access_key = gems$access_key), session), app))
  expect_true(body$BIOM$is_editor)
})


test_that("with no project to open, the session cannot start", {

  REQ  <- local_test_req()
  resp <- handle_request(fake_request("POST", "/api/session/init", list()), test_app(REQ))

  expect_identical(resp$status, 404L)

  # The failed attempt left no guest account behind.
  expect_null(db_query(REQ$DB, "SELECT user_id FROM users", "T1"))
  expect_null(db_query(REQ$DB, "SELECT user_id FROM auth_tokens", "T2"))
})


test_that("the tree routes work on public and private nodes", {

  REQ <- local_seeded_req()
  app <- test_app(REQ)

  session <- session_from(handle_request(fake_request("POST", "/api/session/init", list()), app))
  post    <- function (path, args = list()) handle_request(fake_request("POST", path, args, session), app)

  gems <- db_query(REQ$DB, "SELECT project_id FROM projects WHERE public_key = 'gems'", "T1")

  # Select a public project by its node.
  resp <- post("/api/tree/select", list(node_id = paste0("G", gems)))
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$BIOM$public_key, "gems")

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
  expect_identical(db_query(REQ$DB, "SELECT jstree_text FROM collections WHERE user_id = ?", "T3", list(other)), "Their studies")

  # So is another user's private project, by its tree node or as if public.
  private <- add_test_project(REQ$DB, other, "Their study")
  expect_identical(post("/api/tree/select", list(node_id = paste0("P", private$permission_id)))$status, 403L)
  expect_identical(post("/api/tree/select", list(node_id = paste0("G", private$project_id)))$status, 403L)
  expect_identical(post("/api/tree/leave",  list(node_id = paste0("P", private$permission_id)))$status, 403L)
  expect_identical(post("/api/tree/move",   list(node_id = paste0("P", private$permission_id), parent_node_id = outer))$status, 403L)
  expect_identical(project_access(REQ$DB, private$project_id, other), "editor")
})


test_that("an editor who has signed in can publish and unpublish the open project", {

  REQ    <- local_seeded_req()
  DB     <- REQ$DB
  app    <- test_app(REQ)
  editor <- add_test_user(DB, "Edith Editor")
  viewer <- add_test_user(DB, "Victor Viewer")
  admin  <- add_test_user(DB, "Adam Admin", is_admin = TRUE)

  pid <- add_test_project(DB, editor, "My study")$project_id
  db_query(DB, "UPDATE projects SET full_bf_id = p.full_bf_id, rare_bf_id = p.rare_bf_id FROM (SELECT full_bf_id, rare_bf_id FROM projects WHERE public_key = 'hmp50') AS p WHERE project_id = ?", "T0", list(pid))
  db_insert(DB, "permissions", "T1", user_id = viewer, project_id = pid, is_editor = FALSE)

  public  <- create_collection(DB, NULL, NULL, "Examples")
  private <- create_collection(DB, editor, NULL, "Mine")

  keys <- function () db_query(DB, "SELECT access_key, public_key, public_collection_id FROM projects WHERE project_id = ?", "T2", list(pid))
  post <- function (user_id, args) handle_request(fake_request("POST", "/api/project/publish", args, add_test_session(DB, user_id, pid)), app)

  private_key <- keys()$access_key

  # A viewer cannot publish, and a public key has to be given and be free.
  expect_identical(post(viewer, list(is_public = TRUE, public_key = "my-study"))$status, 403L)
  expect_identical(post(editor, list(is_public = TRUE))$status, 400L)
  expect_identical(post(editor, list(is_public = TRUE, public_key = "hmp50"))$status, 400L)
  expect_identical(post(editor, list(is_public = TRUE, public_key = private_key))$status, 400L)
  for (key in c("api", "auth", "www", "tmp", "abc", "My-Study", "-study", "study-", "my_study", strrep("a", 21)))
    expect_identical(post(editor, list(is_public = TRUE, public_key = key))$status, 400L, info = key)

  # A private collection is not a place in the public tree.
  expect_identical(post(editor, list(is_public = TRUE, public_key = "my-study", collection_id = private))$status, 400L)
  expect_true(is.na(keys()$public_key))

  resp <- post(editor, list(is_public = TRUE, public_key = "my-study", collection_id = public))
  expect_identical(resp$status, 200L)
  expect_identical(keys(), list(access_key = private_key, public_key = "my-study", public_collection_id = public))
  expect_true(response_json(resp)$BIOM$is_public)

  node <- Filter(function (n) identical(n$info$access_key, "my-study"), response_json(resp)$tree$public)[[1]]
  expect_identical(node$parent, paste0("C", public))

  # Everyone can read it now, by its public key; administrators can change it.
  expect_identical(project_access(DB, pid, NULL),  "viewer")
  expect_identical(project_access(DB, pid, admin), "editor")
  expect_identical(handle_request(fake_request("GET", "/my-study/rare.json"), app)$status, 200L)

  # Publishing again without a key keeps the key.
  expect_identical(post(editor, list(is_public = TRUE))$status, 200L)
  expect_identical(keys()$public_key, "my-study")

  # Unpublishing takes away the public key and nothing else: the private
  # key, and so every share link, is as it was.
  expect_identical(post(admin, list(is_public = FALSE))$status, 200L)
  expect_identical(keys(), list(access_key = private_key, public_key = NA_character_, public_collection_id = NA_integer_))
  expect_identical(project_access(DB, pid, NULL),   "none")
  expect_identical(project_access(DB, pid, admin),  "none")
  expect_identical(project_access(DB, pid, viewer), "viewer")
  expect_identical(handle_request(fake_request("GET", "/my-study/rare.json"), app)$status, 404L)
  expect_identical(handle_request(fake_request("GET", paste0("/", private_key, "/rare.json")), app)$status, 200L)
})


test_that("an editor can give a project a new private key, which ends old links", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  app    <- test_app(REQ)
  editor <- add_test_user(DB, "Edith Editor")
  viewer <- add_test_user(DB, "Victor Viewer")
  pid    <- add_test_project(DB, editor)$project_id
  db_insert(DB, "permissions", "T1", user_id = viewer, project_id = pid, is_editor = FALSE)

  key  <- function () db_query(DB, "SELECT access_key FROM projects WHERE project_id = ?", "T2", list(pid))
  post <- function (user_id) handle_request(fake_request("POST", "/api/project/new_key", list(), add_test_session(DB, user_id, pid)), app)
  old  <- key()

  expect_identical(post(viewer)$status, 403L)
  expect_identical(key(), old)

  resp <- post(editor)
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$access_key, key())
  expect_match(key(), "^[a-z0-9]{12}$")
  expect_false(identical(key(), old))

  # The old key opens nothing; grants are untouched.
  expect_null(key_project(DB, old))
  expect_identical(key_project(DB, key())$project_id, pid)
  expect_identical(project_access(DB, pid, viewer), "viewer")
})


test_that("BIOM files can be downloaded by project key", {

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

  # A key is matched exactly: no prefix, no other case, no SQL wildcard.
  key <- db_query(REQ$DB, "SELECT access_key FROM projects WHERE public_key = 'hmp50'", "T1")
  expect_identical(handle_request(fake_request("GET", paste0("/", key, "/rare.json")), app)$status, 200L)
  for (wrong in c(substr(key, 1, 11), toupper(key), "HMP50", "hmp5", "hmp%", "____"))
    expect_true(handle_request(fake_request("GET", paste0("/", wrong, "/rare.json")), app)$status %in% c(400L, 404L), info = wrong)
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


test_that("project_access gives each kind of user the right level", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Edith Editor")
  viewer <- add_test_user(DB, "Victor Viewer")
  admin  <- add_test_user(DB, "Adam Admin", is_admin = TRUE)
  guest  <- add_test_user(DB, "Guest 4", is_guest = TRUE)

  private <- add_test_project(DB, editor)$project_id
  public  <- add_test_project(DB, editor, is_public = TRUE)$project_id
  db_insert(DB, "permissions", "T1", user_id = viewer, project_id = private, is_editor = FALSE)

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
})


test_that("key_project and open_by_key tell private keys from public ones", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Edith Editor")
  guest  <- add_test_user(DB, "Guest 4", is_guest = TRUE)

  private <- add_test_project(DB, editor)$project_id
  public  <- add_test_project(DB, editor, is_public = TRUE)$project_id
  keys    <- function (pid) db_query(DB, "SELECT access_key, public_key FROM projects WHERE project_id = ?", "T1", list(pid))

  expect_identical(key_project(DB, keys(private)$access_key), list(project_id = private, private = TRUE))
  expect_identical(key_project(DB, keys(public)$access_key),  list(project_id = public,  private = TRUE))
  expect_identical(key_project(DB, keys(public)$public_key),  list(project_id = public,  private = FALSE))

  for (bad in list("wrong-key", "", NA_character_, NULL, 5L, c("a", "b"), "%"))
    expect_null(key_project(DB, bad))

  # A public key gives no grant; a private key gives a view grant, once.
  grants <- function () db_query(DB, "SELECT COUNT(*) FROM permissions WHERE user_id = ?", "T2", list(guest))

  expect_identical(open_by_key(DB, keys(public)$public_key, guest), public)
  expect_identical(grants(), 0L)

  expect_identical(open_by_key(DB, keys(private)$access_key, guest), private)
  expect_identical(open_by_key(DB, keys(private)$access_key, guest), private)
  expect_identical(grants(), 1L)
  expect_identical(project_access(DB, private, guest), "viewer")

  # An editor who uses their own link stays an editor.
  expect_identical(open_by_key(DB, keys(private)$access_key, editor), private)
  expect_identical(project_access(DB, private, editor), "editor")

  expect_null(open_by_key(DB, "wrong-key", guest))
})


test_that("a shared server tells the page who runs it and how long things are kept", {

  # For the "Privacy and terms" page, which a server without accounts
  # does not have.
  local_fake_biom()
  conf <- function (REQ)
    response_json(handle_request(fake_request("POST", "/api/session/init", list()), test_app(REQ)))$CONF

  who <- c("auth", "user_id", "full_name", "is_guest", "is_admin", "legacy")

  REQ <- local_test_req()
  add_test_project(REQ$DB, is_public = TRUE)

  # The retention periods are the server's own settings.
  expect_named(conf(REQ), c(who, "session_hours", "guest_days"))
  expect_equal(conf(REQ)$session_hours, 24)
  expect_equal(conf(REQ)$guest_days, 30)

  REQ$CONFIG$session_ttl <- 2 * 3600
  REQ$CONFIG$guest_ttl   <- 7 * 86400
  REQ$CONFIG$operator    <- "the Example Lab at Example University"
  REQ$CONFIG$contact     <- "help@example.org"

  expect_named(conf(REQ), c(who, "session_hours", "guest_days", "operator", "contact"))
  expect_equal(conf(REQ)$session_hours, 2)
  expect_equal(conf(REQ)$guest_days, 7)
  expect_identical(conf(REQ)$operator, "the Example Lab at Example University")
  expect_identical(conf(REQ)$contact, "help@example.org")

  # One of the two may be set without the other.
  REQ$CONFIG$operator <- NULL
  expect_named(conf(REQ), c(who, "session_hours", "guest_days", "contact"))

  # A local install says none of it, whatever its settings.
  local <- local_test_req(auth = "none")
  add_test_project(local$DB, is_public = TRUE)
  local$CONFIG$operator <- "the Example Lab at Example University"
  local$CONFIG$contact  <- "help@example.org"
  expect_named(conf(local), who)

  expect_null(shared_server_conf(list(auth = "none", session_ttl = 3600, guest_ttl = 86400, operator = "x")))
})


test_that("new private keys are random, long enough and unique", {

  REQ  <- local_test_req()
  keys <- replicate(200, new_access_key(REQ$DB))

  expect_true(all(grepl("^[a-z0-9]{12}$", keys)))
  expect_identical(anyDuplicated(keys), 0L)

  # Every one of the 36 symbols turns up, in every position.
  chars <- do.call(rbind, strsplit(replicate(2000, random_key(12)), ""))
  expect_setequal(unique(as.vector(chars)), c(letters, 0:9))
  expect_true(all(apply(chars, 2, function (col) length(unique(col))) == 36))
})
