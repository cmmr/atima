# Regression tests for the allow-list checks.
#
# A local `is_string(x, null_ok)` once shadowed `rlang::is_string(x, string)`,
# which turned every allow-list into "is this a non-empty string". These tests
# fail if any of those checks stops enforcing again.
#
# Allow-lists for request arguments (plot function, upload component, export
# type, ...) are declared in the route table and tested in test-router.R.
# The SQL verb list is tested in test-db.R.


test_that("no local function shadows an imported one", {
  ns      <- asNamespace("atima")
  imports <- parent.env(ns)
  expect_identical(intersect(ls(ns, all.names = TRUE), ls(imports, all.names = TRUE)), character(0))
  expect_false(exists("is_string", envir = ns, inherits = FALSE))
})


test_that("is_one_of only accepts a single string from the list", {

  expect_true(is_one_of("a", c("a", "b")))

  expect_false(is_one_of("c",         c("a", "b")))
  expect_false(is_one_of("",          c("a", "b")))
  expect_false(is_one_of("A",         c("a", "b")))
  expect_false(is_one_of(c("a", "b"), c("a", "b")))
  expect_false(is_one_of(NA_character_, c("a", NA)))
  expect_false(is_one_of(NULL,        c("a", "b")))
  expect_false(is_one_of(1L,          c("a", "b")))
  expect_false(is_one_of(list("a"),   c("a", "b")))

  # A missing allow-list matches nothing (rlang::is_string(x, NULL) is TRUE).
  expect_false(is_one_of("a", NULL))
  expect_false(is_one_of("a", character(0)))
})



test_that("get_biom_component refuses unknown component names", {

  local_mocked_bindings(with_cache = function (...) stop("reached with_cache"))

  for (rbiom_fn in c("system", "clone", "initialize", ".__enclos_env__", "Metadata", ""))
    expect_error(get_biom_component(list(), 1L, rbiom_fn), "is_one_of(rbiom_fn", fixed = TRUE, info = rbiom_fn)

  expect_error(get_biom_component(list(), 1L, "metadata"), "reached with_cache")
})



test_that("metadata field names must be real columns", {

  md <- data.frame(Sex = factor(c("F", "M", "F")), Age = c(20, 30, NA))
  local_mocked_bindings(get_biom_component = function (...) md)
  REQ <- list(SESSION = list(rare_bf_id = 1L))

  for (field in c("nope", "sex", "", "Sex, Age")) {
    expect_error(api_metadata_levels(REQ, field), "Unknown metadata field", class = "atima_http_error", info = field)
    expect_error(api_metadata_minmax(REQ, field), "Unknown metadata field", class = "atima_http_error", info = field)
  }
  expect_error(api_metadata_levels(REQ, c("Sex", "Age")), "Unknown metadata field", class = "atima_http_error")

  # The right kind of column for each question.
  expect_error(api_metadata_levels(REQ, "Age"), "not categorical", class = "atima_http_error")
  expect_error(api_metadata_minmax(REQ, "Sex"), "not numeric",     class = "atima_http_error")

  expect_identical(api_metadata_levels(REQ, "Sex")$default, c("F", "M"))
  expect_identical(api_metadata_minmax(REQ, "Age"), list(min = 20, max = 30))
})


test_that("permission strings are restricted", {

  for (permissions in c("owner", "admin", "EDIT", "", "view,edit")) {

    expect_error(
      update_permissions(DB = NULL, user_id = 5L, project_id = 1L, permissions = permissions),
      regexp = "is_one_of(permissions", fixed = TRUE, info = permissions )

    expect_error(
      can_grant(DB = NULL, user_id = 5L, grantor_user_id = 6L, project_id = 1L, permissions = permissions),
      regexp = "is_one_of(permissions", fixed = TRUE, info = permissions )
  }

  # A listed value gets past the check (and fails later, with no database).
  local_mocked_bindings(db_query = function (...) stop("reached db_query"))
  expect_error(update_permissions(NULL, 5L, 1L, "view"), "reached db_query")
})


test_that("header and cookie strings are still validated", {

  expect_true(valid_string("abc-DEF_1", ok = "-_"))
  expect_false(valid_string("",        ok = "-_"))
  expect_false(valid_string("a b",     ok = "-_"))
  expect_false(valid_string("a\r\nb",  no = ";"))
  expect_false(valid_string(NA_character_))
  expect_false(valid_string(c("a", "b")))
  expect_true(valid_string(NULL, null_ok = TRUE))
  expect_false(valid_string(NULL))

  expect_error(header(name = "X-Test", value = "a\r\nSet-Cookie: b"))
  expect_error(cookie(name = "id", value = "a;b"))
  expect_s3_class(cookie(name = "id", value = "abc123", http_only = TRUE), "header")
  expect_identical(response("hi")$status, 200L)
})
