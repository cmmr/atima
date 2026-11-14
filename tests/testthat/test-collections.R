test_that("an empty collection can be deleted, a non-empty one cannot", {

  # Regression: the "does it still hold projects" query was passed the
  # collection id in place of the SQL, so deleting always failed.
  REQ  <- local_test_req()
  DB   <- REQ$DB
  user <- add_test_user(DB, "Ada Lovelace")
  REQ$SESSION <- list(user_id = user)

  empty <- create_collection(DB, user, NULL, "Empty collection")
  full  <- create_collection(DB, user, NULL, "Full collection")
  add_test_project(DB, user, collection_id = full)

  expect_identical(api_tree_delete(REQ, paste0("C", empty)), list())
  expect_false(db_row_exists(DB, "collections", empty, assert = FALSE))

  expect_error(api_tree_delete(REQ, paste0("C", full)), "non-empty")
  expect_true(db_row_exists(DB, "collections", full, assert = FALSE))
})


test_that("a collection can only be deleted by its owner", {

  REQ   <- local_test_req()
  DB    <- REQ$DB
  owner <- add_test_user(DB, "Ada Lovelace")
  other <- add_test_user(DB, "Charles Babbage")
  coll  <- create_collection(DB, owner, NULL, "Private collection")
  pid   <- add_test_project(DB, other)$project_id

  resp <- handle_request(
    fake_request("POST", "/api/tree/delete", list(node_id = paste0("C", coll)), add_test_session(DB, other, pid)),
    test_app(REQ) )

  expect_identical(resp$status, 403L)
  expect_match(response_json(resp)$error$message, "not yours")
  expect_true(db_row_exists(DB, "collections", coll, assert = FALSE))
})


test_that("an editor can rename a project from the tree", {

  # Regression: renaming the open project called a function that did not
  # exist, and renaming any other project silently did nothing.
  REQ    <- local_test_req()
  DB     <- REQ$DB
  user   <- add_test_user(DB, "Ada Lovelace")
  open   <- add_test_project(DB, user, "Open project")
  closed <- add_test_project(DB, user, "Closed project")
  REQ$SESSION <- list(user_id = user, project_id = open$project_id)

  title <- function (project_id)
    db_query(DB, "SELECT title FROM projects WHERE project_id = ?", "Test1", list(project_id))

  resp <- api_tree_rename(REQ, paste0("P", open$permission_id), "Renamed open project")
  expect_identical(resp, list(title = jsonlite::unbox("Renamed open project")))
  expect_identical(title(open$project_id), "Renamed open project")

  resp <- api_tree_rename(REQ, paste0("P", closed$permission_id), "Renamed closed project")
  expect_identical(resp, list())
  expect_identical(title(closed$project_id), "Renamed closed project")

  # The router trims names and refuses ones that are too short or too long.
  rename <- match_route("POST", "/api/tree/rename")$route
  expect_identical(validate_args(rename, list(node_id = "P1", text = "  Padded name "))$text, "Padded name")
  expect_error(validate_args(rename, list(node_id = "P1", text = "x")), class = "atima_http_error")
  expect_error(validate_args(rename, list(node_id = "P1", text = strrep("x", 101))), class = "atima_http_error")
})


test_that("a viewer cannot rename a project", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  viewer <- add_test_user(DB, "Charles Babbage")
  proj   <- add_test_project(DB, viewer, "Read-only project", is_editor = FALSE)

  session <- add_test_session(DB, viewer, proj$project_id)
  node    <- paste0("P", proj$permission_id)
  post    <- function (path, args) handle_request(fake_request("POST", path, args, session), test_app(REQ))

  resp <- post("/api/tree/rename", list(node_id = node, text = "Hijacked title"))
  expect_identical(resp$status, 403L)
  expect_match(response_json(resp)$error$message, "do not have permission")

  # Nor delete it for everyone. Leaving it is theirs to do.
  expect_identical(post("/api/tree/delete", list(node_id = node))$status, 403L)
  expect_identical(project_access(DB, proj$project_id, viewer), "viewer")

  title <- db_query(DB, "SELECT title FROM projects WHERE project_id = ?", "Test1", list(proj$project_id))
  expect_identical(title, "Read-only project")
})


# The public tree ---------------------------------------------------------------

# A shared server with an administrator, an ordinary user, a guest, and a
# public project that the user published. Everyone has a session on it.
local_public_tree <- function (env = parent.frame()) {

  REQ <- local_test_req(env)
  DB  <- REQ$DB

  users <- list(
    admin = add_test_user(DB, "Adam Admin", is_admin = TRUE),
    user  = add_test_user(DB, "Ada Lovelace"),
    guest = add_test_user(DB, "Guest 3", is_guest = TRUE) )

  public   <- add_test_project(DB, users$user, "Public project", is_public = TRUE)
  sessions <- lapply(users, function (user_id) add_test_session(DB, user_id, public$project_id))

  list(
    REQ = REQ, DB = DB, users = users, public = public, sessions = sessions,
    post = function (who, path, args = list()) {
      session <- if (is.character(who)) sessions[[who]] else who
      handle_request(fake_request("POST", path, args, session), test_app(REQ))
    },
    collection = function (id) {
      db_query(DB, "SELECT user_id, parent_collection_id, jstree_text FROM collections WHERE collection_id = ?", "T1", list(id))
    },
    listed_under = function (project_id) {
      DBI::dbGetQuery(DB, "SELECT public_key, public_collection_id FROM projects WHERE project_id = ?", params = list(project_id))
    })
}


test_that("an administrator creates, renames, nests and deletes public collections", {

  s <- local_public_tree()

  # At the top of the public tree. The name is trimmed like any other.
  resp <- s$post("admin", "/api/public/create", list(parent_node_id = "#", text = "  Gut studies "))
  expect_identical(resp$status, 200L)
  node <- response_json(resp)$node
  expect_identical(node[c("parent", "text")], list(parent = "#", text = "Gut studies"))
  expect_match(node$id, "^C[0-9]+$")
  top <- node_number(node$id)

  # It belongs to nobody, which is what makes it public.
  expect_identical(s$collection(top), list(user_id = NA_integer_, parent_collection_id = NA_integer_, jstree_text = "Gut studies"))

  # Inside another public collection.
  resp  <- s$post("admin", "/api/public/create", list(parent_node_id = node$id, text = "Infants"))
  expect_identical(resp$status, 200L)
  inner <- node_number(response_json(resp)$node$id)
  expect_identical(response_json(resp)$node$parent, node$id)
  expect_identical(s$collection(inner)$parent_collection_id, top)

  resp <- s$post("admin", "/api/public/rename", list(node_id = paste0("C", inner), text = "Infant cohorts"))
  expect_identical(resp$status, 200L)
  expect_identical(s$collection(inner)$jstree_text, "Infant cohorts")

  # Everyone sees them in the public tree, and nobody in their own.
  REQ <- s$REQ
  for (who in names(s$users)) {
    REQ$SESSION <- list(user_id = s$users[[who]], is_admin = who == "admin")
    tree <- tree_data(REQ)
    ids  <- function (nodes) vapply(nodes, function (n) as.character(n$id), "")
    expect_true(all(paste0("C", c(top, inner)) %in% ids(tree$public)), info = who)
    expect_false(any(startsWith(ids(tree$private), "C")), info = who)
  }

  # Names are checked like any other.
  expect_identical(s$post("admin", "/api/public/rename", list(node_id = paste0("C", inner), text = "x"))$status, 400L)
  expect_identical(s$post("admin", "/api/public/create", list(parent_node_id = "#", text = strrep("x", 101)))$status, 400L)
  expect_identical(s$post("admin", "/api/public/create", list(parent_node_id = "#"))$status, 400L)

  # Out of its parent, then gone.
  resp <- s$post("admin", "/api/public/move", list(node_id = paste0("C", inner), parent_node_id = "#"))
  expect_identical(resp$status, 200L)
  expect_identical(s$collection(inner)$parent_collection_id, NA_integer_)

  for (id in c(inner, top)) {
    expect_identical(s$post("admin", "/api/public/delete", list(node_id = paste0("C", id)))$status, 200L)
    expect_false(db_row_exists(s$DB, "collections", id, assert = FALSE))
  }
})


test_that("an administrator moves public collections and public projects within the public tree", {

  s     <- local_public_tree()
  outer <- create_collection(s$DB, NULL, NULL, "Outer")
  inner <- create_collection(s$DB, NULL, outer, "Inner")
  other <- create_collection(s$DB, NULL, NULL, "Other")
  node  <- function (id) paste0("C", id)
  pid   <- s$public$project_id

  move <- function (node_id, parent_node_id) s$post("admin", "/api/public/move", list(node_id = node_id, parent_node_id = parent_node_id))

  # A public project is listed under a collection, and at the top again.
  expect_identical(move(paste0("G", pid), node(inner))$status, 200L)
  expect_identical(s$listed_under(pid)$public_collection_id, as.integer(inner))
  expect_identical(move(paste0("G", pid), "#")$status, 200L)
  expect_true(is.na(s$listed_under(pid)$public_collection_id))

  # A collection goes into another, but not into itself or a descendant.
  expect_identical(move(node(other), node(inner))$status, 200L)
  expect_identical(s$collection(other)$parent_collection_id, as.integer(inner))

  for (parent in c(outer, inner, other)) {
    resp <- move(node(outer), node(parent))
    expect_identical(resp$status, 400L, info = parent)
    expect_match(response_json(resp)$error$message, "inside itself")
  }
  expect_true(is.na(s$collection(outer)$parent_collection_id))
})


test_that("only an administrator can change the public tree", {

  s     <- local_public_tree()
  DB    <- s$DB
  coll  <- create_collection(DB, NULL, NULL, "Public collection")
  node  <- paste0("C", coll)
  gnode <- paste0("G", s$public$project_id)

  requests <- list(
    "/api/public/create" = list(parent_node_id = "#", text = "Mine now"),
    "/api/public/create" = list(parent_node_id = node, text = "Mine now"),
    "/api/public/rename" = list(node_id = node, text = "Mine now"),
    "/api/public/move"   = list(node_id = gnode, parent_node_id = node),
    "/api/public/delete" = list(node_id = node) )

  unchanged <- function (info) {
    expect_identical(db_query(DB, "SELECT COUNT(*) FROM collections", "T2"), 1L, info = info)
    expect_identical(s$collection(coll)$jstree_text, "Public collection", info = info)
    expect_true(is.na(s$listed_under(s$public$project_id)$public_collection_id), info = info)
  }

  # A guest, and a user who is the public project's own editor.
  for (who in c("guest", "user")) {
    for (i in seq_along(requests)) {
      resp <- s$post(who, names(requests)[[i]], requests[[i]])
      info <- paste(who, names(requests)[[i]])
      expect_identical(resp$status, 403L, info = info)
      expect_match(response_json(resp)$error$message, "administrator", info = info)
      unchanged(info)
    }
  }

  # They are refused before their arguments are looked at.
  expect_identical(s$post("user", "/api/public/rename", list(nonsense = 1))$status, 403L)

  # Nobody at all: no session.
  for (i in seq_along(requests))
    expect_identical(s$post(NULL, names(requests)[[i]], requests[[i]])$status, 401L, info = names(requests)[[i]])
  unchanged("no session")

  # Nor through the routes for a user's own tree, where a collection has to
  # be the caller's. That holds for an administrator too.
  for (who in c("guest", "user", "admin")) {
    for (path in c("/api/tree/delete", "/api/tree/rename", "/api/tree/create", "/api/tree/move")) {
      args <- switch(
        EXPR = path,
        "/api/tree/rename" = list(node_id = node, text = "Mine now"),
        "/api/tree/move"   = list(node_id = node, parent_node_id = "#"),
        list(node_id = node) )
      resp <- s$post(who, path, args)
      expect_identical(resp$status, 403L, info = paste(who, path))
      expect_match(response_json(resp)$error$message, "not yours", info = paste(who, path))
    }
    unchanged(who)
  }

  # A user cannot file their own project under a public collection either.
  own  <- add_test_project(DB, s$users$user, "Private project")
  resp <- s$post("user", "/api/tree/move", list(node_id = paste0("P", own$permission_id), parent_node_id = node))
  expect_identical(resp$status, 403L)
})


test_that("the owner of a server without accounts is not an administrator", {

  REQ   <- local_test_req(auth = "none")
  DB    <- REQ$DB
  owner <- local_owner(DB)
  coll  <- create_collection(DB, NULL, NULL, "Public collection")
  pid   <- add_test_project(DB, owner, is_public = TRUE)$project_id

  session <- add_test_session(DB, owner, pid)
  post    <- function (path, args) handle_request(fake_request("POST", path, args, session), test_app(REQ))

  expect_identical(post("/api/public/create", list(parent_node_id = "#", text = "Mine now"))$status, 403L)
  expect_identical(post("/api/public/rename", list(node_id = paste0("C", coll), text = "Mine now"))$status, 403L)
  expect_identical(post("/api/public/move",   list(node_id = paste0("G", pid), parent_node_id = paste0("C", coll)))$status, 403L)
  expect_identical(post("/api/public/delete", list(node_id = paste0("C", coll)))$status, 403L)

  expect_identical(db_query(DB, "SELECT jstree_text FROM collections", "T1"), "Public collection")

  # And the page is not told that they are one, so it shows no controls.
  local_fake_biom()
  conf <- response_json(handle_request(fake_request("POST", "/api/session/init", list()), test_app(REQ)))$CONF
  expect_false(conf$is_admin)
})


test_that("the public tree routes reach nothing but the public tree", {

  s    <- local_public_tree()
  DB   <- s$DB
  coll <- create_collection(DB, NULL, NULL, "Public collection")
  node <- paste0("C", coll)

  # A user's own collection, and a private project.
  private <- create_collection(DB, s$users$user, NULL, "Ada's collection")
  hidden  <- add_test_project(DB, s$users$user, "Private project")

  refused <- function (path, args, status = 403L) {
    resp <- s$post("admin", path, args)
    expect_identical(resp$status, status, info = paste(path, paste(unlist(args), collapse = " ")))
  }

  refused("/api/public/rename", list(node_id = paste0("C", private), text = "Renamed by the administrator"))
  refused("/api/public/delete", list(node_id = paste0("C", private)))
  refused("/api/public/move",   list(node_id = paste0("C", private), parent_node_id = node))
  refused("/api/public/move",   list(node_id = node, parent_node_id = paste0("C", private)))
  refused("/api/public/create", list(parent_node_id = paste0("C", private), text = "Inside Ada's"))
  refused("/api/public/move",   list(node_id = paste0("G", hidden$project_id), parent_node_id = node))
  refused("/api/public/move",   list(node_id = "G99999", parent_node_id = node))
  refused("/api/public/delete", list(node_id = "C99999"))

  # A project of somebody's own tree is not a node these routes take at all.
  refused("/api/public/move",   list(node_id = paste0("P", hidden$permission_id), parent_node_id = node), 400L)
  refused("/api/public/rename", list(node_id = paste0("G", s$public$project_id), text = "Renamed"), 400L)
  refused("/api/public/delete", list(node_id = paste0("G", s$public$project_id)), 400L)
  refused("/api/public/delete", list(node_id = "#"), 400L)

  expect_identical(s$collection(private), list(user_id = as.integer(s$users$user), parent_collection_id = NA_integer_, jstree_text = "Ada's collection"))
  expect_identical(s$collection(coll)$parent_collection_id, NA_integer_)
  expect_true(is.na(s$listed_under(hidden$project_id)$public_collection_id))
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM collections", "T2"), 2L)
})


test_that("a public collection that holds something is not deleted", {

  # As with a user's own collections. The foreign key would let the delete
  # through and move the projects to the top of the public tree; nothing is
  # to be rearranged, or unpublished, as a side effect.
  s      <- local_public_tree()
  DB     <- s$DB
  pid    <- s$public$project_id
  coll   <- create_collection(DB, NULL, NULL, "Gut studies")
  inner  <- create_collection(DB, NULL, coll, "Infants")
  node   <- function (id) paste0("C", id)
  delete <- function (id) s$post("admin", "/api/public/delete", list(node_id = node(id)))

  db_update(DB, "projects", pid, "T1", public_collection_id = inner)
  before <- s$listed_under(pid)

  # It holds a collection; that one holds a public project.
  for (id in c(coll, inner)) {
    resp <- delete(id)
    expect_identical(resp$status, 400L, info = id)
    expect_match(response_json(resp)$error$message, "non-empty", info = id)
    expect_true(db_row_exists(DB, "collections", id, assert = FALSE), info = id)
  }

  # The project is as public as it was, and listed where it was.
  expect_identical(s$listed_under(pid), before)
  expect_false(is.na(before$public_key))
  expect_identical(project_access(DB, pid, s$users$guest), "viewer")

  # Once the administrator has moved the project out, both can go, and the
  # project is still public.
  expect_identical(s$post("admin", "/api/public/move", list(node_id = paste0("G", pid), parent_node_id = "#"))$status, 200L)
  expect_identical(delete(inner)$status, 200L)
  expect_identical(delete(coll)$status, 200L)
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM collections", "T2"), 0L)
  expect_identical(s$listed_under(pid)$public_key, before$public_key)
  expect_true(is.na(s$listed_under(pid)$public_collection_id))
})
