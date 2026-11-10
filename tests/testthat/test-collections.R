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

  REQ$SESSION <- list(user_id = other)
  expect_error(api_jstree_delete(REQ, paste0("C", coll)))
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

  resp <- api_jstree_rename(REQ, paste0("P", open$permission_id), "  Renamed open project ")
  expect_identical(resp, list(title = jsonlite::unbox("Renamed open project")))
  expect_identical(title(open$project_id), "Renamed open project")

  resp <- api_jstree_rename(REQ, paste0("P", closed$permission_id), "Renamed closed project")
  expect_identical(resp, list())
  expect_identical(title(closed$project_id), "Renamed closed project")

  # Titles go through the usual checks.
  expect_error(api_jstree_rename(REQ, paste0("P", open$permission_id), "x"))
  expect_identical(title(open$project_id), "Renamed open project")
})


test_that("a viewer cannot rename a project", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  viewer <- add_test_user(DB, "Charles Babbage")
  proj   <- add_test_project(DB, viewer, "Read-only project", is_editor = FALSE)
  REQ$SESSION <- list(user_id = viewer, project_id = proj$project_id)

  expect_error(
    api_jstree_rename(REQ, paste0("P", proj$permission_id), "Hijacked title"),
    "do not have permission" )

  title <- db_query(DB, "SELECT title FROM projects WHERE project_id = ?", "Test1", list(proj$project_id))
  expect_identical(title, "Read-only project")
})
