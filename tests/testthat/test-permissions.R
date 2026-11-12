test_that("check_grant follows the grantor's own permission level", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Ada Lovelace")
  viewer <- add_test_user(DB, "Charles Babbage")
  other  <- add_test_user(DB, "Grace Hopper")
  third  <- add_test_user(DB, "Mary Somerville")
  guest  <- add_test_user(DB, "Guest 9", is_guest = TRUE)
  pid    <- add_test_project(DB, editor)$project_id
  update_permissions(DB, viewer, pid, "view", grantor_user_id = editor)

  allowed <- function (user_id, grantor, permissions) {
    tryCatch(
      expr  = isTRUE(check_grant(DB, user_id, grantor, pid, permissions)),
      atima_http_error = function (e) FALSE )
  }

  # Editors can grant anything to people with accounts.
  expect_true(allowed(other, editor, "view"))
  expect_true(allowed(other, editor, "edit"))
  expect_true(allowed(viewer, editor, "edit"))
  expect_true(allowed(viewer, editor, "none"))

  # Viewers can share read access, not editing rights.
  expect_true( allowed(other, viewer, "view"))
  expect_false(allowed(other, viewer, "edit"))
  expect_error(check_grant(DB, other, viewer, pid, "edit"), "Insufficient rights", class = "atima_http_error")

  # A viewer cannot touch an editor's grant, or a grant someone else made.
  expect_false(allowed(editor, viewer, "none"))
  update_permissions(DB, other, pid, "view", grantor_user_id = editor)
  expect_false(allowed(other, viewer, "none"))

  # A viewer can take back what they themselves passed on.
  update_permissions(DB, third, pid, "view", grantor_user_id = viewer)
  expect_true(allowed(third, viewer, "none"))

  # Users with no access cannot grant, and nothing is granted to a guest.
  update_permissions(DB, other, pid, "none")
  expect_false(allowed(viewer, other, "view"))
  expect_false(allowed(guest, editor, "view"))
  expect_identical(expect_error(check_grant(DB, viewer, other, pid, "view"), class = "atima_http_error")$status, 403L)

  expect_error(check_grant(DB, other, editor, pid, "admin"))
})


test_that("a project always keeps at least one editor", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  first  <- add_test_user(DB, "Ada Lovelace")
  second <- add_test_user(DB, "Grace Hopper")
  pid    <- add_test_project(DB, first)$project_id

  # The only editor cannot be removed or demoted, not even by themselves.
  expect_error(check_grant(DB, first, first, pid, "none"), "at least one editor", class = "atima_http_error")
  expect_error(check_grant(DB, first, first, pid, "view"), "at least one editor", class = "atima_http_error")

  # With a second editor, either can go.
  update_permissions(DB, second, pid, "edit", grantor_user_id = first)
  expect_true(check_grant(DB, first, second, pid, "none"))
  expect_true(check_grant(DB, second, first, pid, "view"))
})


test_that("nobody is granted view access to a public project", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  editor <- add_test_user(DB, "Ada Lovelace")
  other  <- add_test_user(DB, "Grace Hopper")
  admin  <- add_test_user(DB, "Adam Admin", is_admin = TRUE)
  pid    <- add_test_project(DB, editor, is_public = TRUE)$project_id

  expect_error(check_grant(DB, other, editor, pid, "view"), "already viewable", class = "atima_http_error")
  expect_true(check_grant(DB, other, editor, pid, "edit"))

  # An administrator can change who edits a public project.
  expect_true(check_grant(DB, other, admin, pid, "edit"))

  # ...but cannot give themselves a grant that would outlast its being public.
  for (permissions in c("edit", "view", "any"))
    expect_error(check_grant(DB, admin, admin, pid, permissions), class = "atima_http_error", info = permissions)

  # Someone who can merely see it cannot.
  expect_error(check_grant(DB, admin, other, pid, "edit"), class = "atima_http_error")
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


test_that("the sharing routes apply the grant rule and need an account", {

  REQ    <- local_test_req()
  DB     <- REQ$DB
  app    <- test_app(REQ)
  editor <- add_test_user(DB, "Ada Lovelace")
  viewer <- add_test_user(DB, "Charles Babbage")
  other  <- add_test_user(DB, "Grace Hopper")
  guest  <- add_test_user(DB, "Guest 9", is_guest = TRUE)
  pid    <- add_test_project(DB, editor)$project_id
  update_permissions(DB, viewer, pid, "view", grantor_user_id = editor)
  update_permissions(DB, guest,  pid, "view")

  post <- function (user_id, path, args = list())
    handle_request(fake_request("POST", path, args, add_test_session(DB, user_id, pid)), app)

  # A viewer may pass on view access but not editing rights.
  expect_identical(post(viewer, "/api/sharing/update", list(user_id = other, permissions = "edit"))$status, 403L)
  expect_identical(post(viewer, "/api/sharing/update", list(user_id = other, permissions = "view"))$status, 200L)
  expect_identical(project_access(DB, pid, other), "viewer")

  # The last editor stays.
  resp <- post(editor, "/api/sharing/update", list(user_id = editor, permissions = "none"))
  expect_identical(resp$status, 400L)
  expect_identical(project_access(DB, pid, editor), "editor")

  # A guest who can view the project (they opened its link) cannot see who
  # else has access, search for users, or grant anything.
  expect_identical(post(guest, "/api/project/export", list(what = "metadata", nonsense = 1))$status, 400L)
  for (path in c("/api/sharing/list", "/api/sharing/editors"))
    expect_identical(post(guest, path)$status, 403L, info = path)
  expect_identical(post(guest, "/api/sharing/user_search", list(query = "ada"))$status, 403L)
  expect_identical(post(guest, "/api/sharing/update", list(user_id = other, permissions = "view"))$status, 403L)
})


test_that("other users see a name, an affiliation and a redacted email, nothing more", {

  REQ <- local_test_req()
  DB  <- REQ$DB
  ada <- add_test_user(DB, "Ada Lovelace")
  db_update(DB, "users", ada, "T1", email = "ada.lovelace@example.org", affiliation = "Analytical Engines", issuer = "https://issuer.test", sub = "sub-ada")
  orcid <- add_test_user(DB, "Rosalind Franklin")
  db_update(DB, "users", orcid, "T2", issuer = "https://orcid.org", sub = "0000-0002-1825-0097")
  add_test_user(DB, "Guest 3", is_guest = TRUE)

  me  <- add_test_user(DB, "Grace Hopper")
  pid <- add_test_project(DB, me)$project_id
  update_permissions(DB, ada, pid, "edit", grantor_user_id = me)
  REQ$SESSION <- list(user_id = me, project_id = pid, is_public = FALSE)

  found <- api_sharing_user_search(REQ, "lovelace")$users
  expect_named(found, c("user_id", "full_name", "affiliation", "email", "orcid"))
  expect_identical(found$full_name[[1]], "Ada Lovelace")
  expect_identical(found$email[[1]], "ad********ce@example.org")
  expect_true(is.na(found$orcid[[1]]))
  expect_false(any(grepl("Guest", found$full_name)))

  # Someone with no email (ORCID sends none) is found by name, and is shown
  # with their ORCID iD, which is what tells two people of one name apart.
  found <- api_sharing_user_search(REQ, "Rosalind")$users
  expect_identical(found$full_name[[1]], "Rosalind Franklin")
  expect_true(is.na(found$email[[1]]))
  expect_identical(found$orcid[[1]], "0000-0002-1825-0097")
  expect_identical(api_sharing_user_search(REQ, "0000-0002-1825")$users$full_name[[1]], "Rosalind Franklin")

  editors <- api_get_editors(REQ)$users
  expect_named(editors, c("user_id", "full_name", "affiliation", "email", "orcid"))
  expect_setequal(editors$full_name, c("Ada Lovelace", "Grace Hopper"))

  shared <- api_sharing_with(REQ)$users
  expect_named(shared, c("user_id", "full_name", "affiliation", "email", "is_editor", "orcid"))
  expect_identical(shared$is_editor, c(TRUE, TRUE))

  # An ORCID iD is public. What any other provider calls a person, and
  # their whole email address, never leave the server.
  everything <- paste(unlist(list(api_sharing_user_search(REQ, "lovelace")$users, editors, shared)), collapse = " ")
  expect_no_match(everything, "sub-ada")
  expect_no_match(everything, "issuer.test")
  expect_no_match(everything, "ada.lovelace@")
})


test_that("redact_emails hides most of the user name", {

  expect_identical(
    redact_emails(c("ada@example.org", "charles.babbage@example.org", "not-an-email", NA)),
    c("a**@example.org", "ch***********ge@example.org", "not-an-email", NA) )
})
