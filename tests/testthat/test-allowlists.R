# Regression tests for the allow-list checks.
#
# A local `is_string(x, null_ok)` once shadowed `rlang::is_string(x, string)`,
# which turned every allow-list into "is this a non-empty string". These tests
# fail if any of those checks stops enforcing again.


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


test_that("api_plot refuses a plot_fn outside its list", {

  bad <- c("system", "write_biom", "adiv_boxplot; q()", "ggsave", "", "ADIV_BOXPLOT")
  for (plot_fn in bad)
    expect_error(
      api_plot(REQ = list(), plot_fn = plot_fn, plot_args = list(), depth = 100),
      regexp = "is_one_of(plot_fn", fixed = TRUE, info = plot_fn )

  expect_error(
    api_plot(REQ = list(), plot_fn = c("adiv_boxplot", "system"), plot_args = list(), depth = 100),
    regexp = "is_one_of(plot_fn", fixed = TRUE )

  # The check runs before anything else: nothing downstream is reached.
  local_mocked_bindings(rarefy_if_needed = function (...) stop("reached rarefy_if_needed"))
  expect_error(api_plot(list(), "system",       list(), 100), "is_one_of(plot_fn", fixed = TRUE)
  expect_error(api_plot(list(), "adiv_boxplot", list(), 100), "reached rarefy_if_needed")
})


test_that("db_query only runs allowed SQL verbs", {

  DB <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  on.exit(DBI::dbDisconnect(DB), add = TRUE)
  DBI::dbExecute(DB, "CREATE TABLE t (x INTEGER)")

  for (sql in c(
      "DROP TABLE t", "ALTER TABLE t ADD COLUMN y", "PRAGMA writable_schema = 1",
      "ATTACH DATABASE ':memory:' AS other", "CREATE TABLE u (x)", "VACUUM",
      "REPLACE INTO t VALUES (1)", "WITH a AS (SELECT 1) SELECT * FROM a" ))
    expect_error(db_query(DB, sql, "Test1"), "Invalid SQL verb", info = sql)

  expect_identical(DBI::dbListTables(DB), "t")

  # Verbs the package uses, including the ROLLBACK in delete_account().
  expect_no_error(db_query(DB, "BEGIN", "Test2"))
  expect_no_error(db_query(DB, "INSERT INTO t VALUES (?)", "Test3", list(1L)))
  expect_no_error(db_query(DB, "ROLLBACK", "Test4"))
  expect_identical(db_query(DB, "SELECT COUNT(*) FROM t", "Test5"), 0L)

  expect_no_error(db_query(DB, "BEGIN", "Test6"))
  expect_no_error(db_query(DB, "  insert into t values (?)", "Test7", list(2L)))
  expect_no_error(db_query(DB, "UPDATE t SET x = 3", "Test8"))
  expect_no_error(db_query(DB, "COMMIT", "Test9"))
  expect_identical(db_query(DB, "SELECT x FROM t", "Test10"), 3L)
  expect_no_error(db_query(DB, "DELETE FROM t", "Test11"))
})


test_that("api_upload_component refuses unknown components", {

  upload <- function (component)
    api_upload_component(
      REQ            = list(),
      component      = list(value = charToRaw(component)),
      component_file = list(value = as.raw(1:3)) )

  for (component in c("counts", "sequences", "id", "Metadata", "class"))
    expect_error(upload(component), "is_one_of(component", fixed = TRUE, info = component)

  # A listed component gets past the check (and fails later, with no session).
  local_mocked_bindings(get_biom = function (...) stop("reached get_biom"))
  for (component in c("metadata", "taxonomy", "tree"))
    expect_error(upload(component), "reached get_biom", info = component)
})


test_that("get_biom_component refuses unknown component names", {

  local_mocked_bindings(with_cache = function (...) stop("reached with_cache"))

  for (rbiom_fn in c("system", "clone", "initialize", ".__enclos_env__", "Metadata", ""))
    expect_error(get_biom_component(list(), 1L, rbiom_fn), "is_one_of(rbiom_fn", fixed = TRUE, info = rbiom_fn)

  expect_error(get_biom_component(list(), 1L, "metadata"), "reached with_cache")
})


test_that("api_export refuses unknown file extensions", {

  local_mocked_bindings(
    db_query = function (...) list(full_bf_id = 1L, rare_bf_id = 2L, orig_bf_id = 3L),
    get_biom = function (...) NULL )

  REQ <- list(PATH = "/api/export/biom/rare/exe", SESSION = list(project_id = 1L))
  expect_error(api_export(REQ), "Invalid file extension")
})


test_that("metadata field names must be real columns", {

  md <- data.frame(Sex = factor(c("F", "M", "F")), Age = c(20, 30, NA))
  local_mocked_bindings(get_biom_component = function (...) md)
  REQ <- list(SESSION = list(rare_bf_id = 1L))

  for (field in c("nope", "sex", "", "Sex, Age")) {
    expect_error(api_metadata_levels(REQ, field), "is_one_of(field", fixed = TRUE, info = field)
    expect_error(api_metadata_minmax(REQ, field), "is_one_of(field", fixed = TRUE, info = field)
  }
  expect_error(api_metadata_levels(REQ, c("Sex", "Age")), "is_one_of(field", fixed = TRUE)

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
