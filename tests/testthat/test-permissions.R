test_that("can_grant follows the grantor's own permission level", {

  # Regression: can_grant() called an undefined function, so every call
  # failed before any rule was looked at.
  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Ada Lovelace")
  viewer <- add_test_user(DB, "Charles Babbage")
  other  <- add_test_user(DB, "Grace Hopper")
  guest  <- add_test_user(DB, "Guest 9", is_guest = TRUE)
  pid    <- add_test_project(DB, editor)$project_id
  update_permissions(DB, viewer, pid, "view", grantor_user_id = editor)

  # Editors can grant anything to registered users.
  expect_true(can_grant(DB, other, editor, pid, "view"))
  expect_true(can_grant(DB, other, editor, pid, "edit"))

  # Viewers can share read access, not editing rights.
  expect_true( can_grant(DB, other, viewer, pid, "view"))
  expect_false(can_grant(DB, other, viewer, pid, "edit"))
  expect_error(
    can_grant(DB, other, viewer, pid, "edit", assert = TRUE),
    "Insufficient rights" )

  # Users with no access cannot grant; guests are never involved.
  expect_false(can_grant(DB, viewer, other, pid, "view"))
  expect_false(can_grant(DB, guest, editor, pid, "view"))
  expect_false(can_grant(DB, other, guest,  pid, "view"))

  expect_error(can_grant(DB, other, editor, pid, "admin"))
  expect_error(can_grant(DB, other, editor, pid, "view", assert = NA))
})


test_that("api_update_permissions grants and revokes access", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Ada Lovelace")
  other  <- add_test_user(DB, "Grace Hopper")
  pid    <- add_test_project(DB, editor)$project_id
  REQ$SESSION <- list(user_id = editor, project_id = pid)

  is_editor <- function ()
    db_query(
      DB, "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?",
      "Test1", list(other, pid) )

  expect_null(is_editor())

  expect_identical(api_update_permissions(REQ, other, "view"), list())
  expect_identical(is_editor(), FALSE)

  expect_identical(api_update_permissions(REQ, other, "edit"), list())
  expect_identical(is_editor(), TRUE)

  expect_identical(api_update_permissions(REQ, other, "none"), list())
  expect_null(is_editor())
})


test_that("redact_emails hides most of the user name", {

  expect_identical(
    unname(redact_emails(c("ada@example.org", "charles.babbage@example.org", "not-an-email"))),
    c("a**@example.org", "ch***********ge@example.org", "not-an-email") )
})
