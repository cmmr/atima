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

  expect_identical(api_jstree_delete(REQ, paste0("C", empty)), list())
  expect_false(db_row_exists(DB, "collections", empty, assert = FALSE))

  expect_error(api_jstree_delete(REQ, paste0("C", full)), "non-empty")
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

  resp <- api_jstree_rename(REQ, paste0("P", open$permission_id), "Renamed open project")
  expect_identical(resp, list(title = jsonlite::unbox("Renamed open project")))
  expect_identical(title(open$project_id), "Renamed open project")

  resp <- api_jstree_rename(REQ, paste0("P", closed$permission_id), "Renamed closed project")
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
