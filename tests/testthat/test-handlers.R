# The compute handlers end to end, with real example data: the main-process
# part, the worker function and the finish step. Jobs run in the test
# process here; test-async.R runs the same routes through worker processes.


# A seeded database and a guest session on hmp50.
local_open_project <- function (env = parent.frame()) {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req(env)
  db_seed(REQ$DB, REQ$CONFIG)

  app  <- test_app(REQ)
  resp <- handle_request(fake_request("POST", "/api/session/init", list()), app)

  session <- list(
    auth_token  = sub("^auth_token=([A-Za-z0-9]+);.*$", "\\1", resp$headers[['Set-Cookie']]),
    session_key = resp$headers[['x-session-key']] )

  list(
    REQ     = REQ,
    DB      = REQ$DB,
    app     = app,
    session = session,
    BIOM    = response_json(resp)$BIOM,
    post    = function (path, args = list()) handle_request(fake_request("POST", path, args, session), app),
    temp    = file.path(REQ$CONFIG$temp_dir, session$session_key) )
}


test_that("the main process never loads a BIOM file or calls rbiom", {

  # Every rbiom function atima imports is used only by code that runs in a
  # worker. Replace them all in the main-process code path and serve a
  # request: nothing may reach them outside worker_run().
  s <- local_open_project()

  in_worker <- FALSE
  real_run  <- worker_run
  forbidden <- function (name) function (...) {
    if (!in_worker) stop("the main process called rbiom::", name, "()")
    get(name, envir = asNamespace("rbiom"))(...)
  }

  local_mocked_bindings(
    worker_run   = function (...) { in_worker <<- TRUE; on.exit(in_worker <<- FALSE); real_run(...) },
    as_rbiom     = forbidden("as_rbiom"),
    rarefy       = forbidden("rarefy"),
    write_biom   = forbidden("write_biom"),
    sample_sums  = forbidden("sample_sums"),
    taxa_means   = forbidden("taxa_means"),
    list_metrics = forbidden("list_metrics"),
    adiv_matrix  = forbidden("adiv_matrix"),
    bdiv_distmat = forbidden("bdiv_distmat"),
    taxa_matrix  = forbidden("taxa_matrix"),
    ggsave       = forbidden("ggsave") )

  expect_identical(s$post("/api/project/rarefy", list(depth = 1000))$status, 200L)
  expect_identical(s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1000))$status, 200L)
  expect_identical(s$post("/api/project/export", list(what = "alpha"))$status, 200L)
  expect_identical(s$post("/api/metadata/table")$status, 200L)
  expect_identical(handle_request(fake_request("GET", "/hmp50/rare.json"), s$app)$status, 200L)
})


test_that("a project summary is computed once and then served from memory", {

  s <- local_open_project()

  expect_identical(s$BIOM$depth, 1183L)
  expect_true(s$BIOM$tree)
  expect_identical(unlist(s$BIOM$cols), c(".sample", "Age", "BMI", "Body Site", "Sex"))
  expect_identical(s$BIOM$col_types$Sex, "cat")

  # A second session on the same project needs no worker at all.
  local_mocked_bindings(worker_run = function (...) stop("a worker was used"))
  resp <- handle_request(fake_request("POST", "/api/session/init", list()), s$app)
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$BIOM$depth, 1183L)
})


test_that("rarefying stores a new file for the draft and leaves the project alone", {

  s <- local_open_project()

  files <- function () db_query(s$DB, "SELECT drafts.rare_bf_id AS draft, projects.rare_bf_id AS project FROM sessions JOIN drafts USING (draft_id) JOIN projects USING (project_id) WHERE session_key = ?", "T1", list(s$session$session_key))

  before <- files()
  expect_identical(before$draft, before$project)

  # Already at this depth: nothing changes and nothing is sent back.
  resp <- s$post("/api/project/rarefy", list(depth = 1183))
  expect_identical(resp$status, 200L)
  expect_length(response_json(resp), 0)
  expect_identical(files(), before)

  resp <- s$post("/api/project/rarefy", list(depth = 2000))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$depth, 2000L)
  expect_false(body$BIOM$is_saved)

  after <- files()
  expect_identical(after$project, before$project)
  expect_false(identical(after$draft, before$draft))

  # The new file is in the store under its own hash.
  row <- db_query(s$DB, "SELECT file, hash FROM biom_files WHERE biom_file_id = ?", "T2", list(after$draft))
  expect_identical(row$file, paste0(row$hash, ".biom"))
  expect_identical(file_sha256(file.path(s$REQ$CONFIG$data_dir, "files", row$file)), row$hash)

  # Rarefying back to a depth seen before reuses the stored file.
  expect_identical(s$post("/api/project/rarefy", list(depth = 1183))$status, 200L)
  expect_identical(files()$draft, before$draft)
})


test_that("a plot is drawn into the session's directory and described in the response", {

  s <- local_open_project()

  resp <- s$post("/api/plot", list(
    plot_fn   = "adiv_boxplot",
    plot_args = list(x = "Body Site", adiv = "Shannon"),
    depth     = 1183,
    attrs     = TRUE ))
  expect_identical(resp$status, 200L)

  body <- response_json(resp)
  expect_match(body$image_url, paste0("^/tmp/", s$session$session_key, "/plot_[A-Za-z0-9]{10}\\.png$"))
  expect_identical(body[c("width", "height", "device", "units")], list(width = 400L, height = 300L, device = "png", units = "px"))
  expect_true(body$attrs)
  expect_null(body$BIOM)

  # The image is complete, and nothing half-written is left next to it.
  image <- file.path(s$temp, basename(body$image_url))
  expect_identical(readBin(image, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)))
  expect_identical(list.files(s$temp), basename(image))

  # Statistics and code come back with `attrs`.
  expect_true(length(body$stats_table) > 0)
  expect_identical(body$code$file, "hmp50/rare.json")
  expect_match(body$code$rbiom, "adiv_boxplot")
  expect_match(body$code$ggplot2, "ggplot")

  # A depth that differs from the draft's rarefies first, and says so.
  resp <- s$post("/api/plot", list(
    plot_fn   = "taxa_stacked",
    plot_args = list(rank = "Phylum"),
    depth     = 1500,
    save_args = list(device = "pdf", width = 6, height = 4, units = "in"),
    subset_args = list(cat = list(Sex = c("Female", "Male")), num = list(Age = c(20, 40))) ))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$depth, 1500L)
  expect_match(body$image_url, "\\.pdf$")
  expect_false(body$attrs)
  expect_null(body$code)

  # rbiom's own message reaches the user for a bad option.
  resp <- s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "No Such Field"), depth = 1500))
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "^The plot could not be made\\.")

  # Bad image settings and subsets are refused.
  bad <- list(
    list(save_args = list(device = "exe")),
    list(save_args = list(units = "furlongs")),
    list(subset_args = list(cat = list(Nope = "x"))),
    list(subset_args = list(num = list(Age = c(1, 2, 3)))) )
  for (extra in bad) {
    args <- c(list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1500), extra)
    expect_identical(s$post("/api/plot", args)$status, 400L, info = names(extra[[1]]))
  }
})


test_that("exports are written once, atomically, under names that say what is inside", {

  s <- local_open_project()

  full <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE access_key = 'hmp50'", "T1")
  rare <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE access_key = 'hmp50'", "T2")
  orig <- db_query(s$DB, "SELECT orig_bf_id FROM projects WHERE access_key = 'hmp50'", "T3")

  url <- function (...) {
    resp <- s$post("/api/project/export", list(...))
    expect_identical(resp$status, 200L)
    response_json(resp)$download_url
  }
  local_path <- function (url) file.path(s$REQ$CONFIG$temp_dir, sub("^/tmp/", "", url))
  base       <- paste0("/tmp/", s$session$session_key, "/")

  expect_identical(url(what = "metadata"),                     sprintf("%s%i/metadata_full_%i.csv", base, full, full))
  expect_identical(url(what = "taxonomy", sample_set = "rare"), sprintf("%s%i/taxonomy_rare_%i.csv", base, rare, rare))
  expect_identical(url(what = "taxa", rank = "Genus"),         sprintf("%s%i/taxa_Genus_full_%i.csv", base, full, full))
  expect_identical(url(what = "alpha", sample_set = "rare"),   sprintf("%s%i/alpha_rare_%i.csv", base, rare, rare))
  expect_identical(url(what = "tree"),                         sprintf("%s%i/tree_full_%i.tre", base, full, full))
  expect_identical(url(what = "biom", format = "tab"),         sprintf("%s%i/biom_full_%i.tab", base, full, full))
  expect_identical(url(what = "original"),                     sprintf("%s%i/original_%i.biom", base, orig, orig))

  # Beta diversity always uses the rarefied counts.
  expect_identical(url(what = "beta", method = "jaccard"),     sprintf("%s%i/beta_jaccard_rare_%i.csv", base, rare, rare))

  md <- utils::read.csv(local_path(url(what = "metadata")), check.names = FALSE)
  expect_identical(colnames(md), c(".sample", "Age", "BMI", "Body Site", "Sex"))
  expect_identical(nrow(md), 50L)

  dm <- utils::read.csv(local_path(url(what = "beta", method = "jaccard")), row.names = 1)
  expect_identical(dim(dm), c(49L, 49L))

  # No temporary files are left among the exports.
  expect_length(list.files(s$temp, pattern = "\\.tmp$", recursive = TRUE), 0)

  # Asking twice reuses the file without a worker.
  local_mocked_bindings(worker_run = function (...) stop("a worker was used"))
  expect_identical(url(what = "metadata"), sprintf("%s%i/metadata_full_%i.csv", base, full, full))
})


test_that("the metadata and taxonomy tables come from a worker", {

  s <- local_open_project()

  page <- response_json(s$post("/api/metadata/table", list(draw = 3, start = 10, length = 5)))
  expect_identical(page$draw, 3L)
  expect_identical(page$recordsTotal, 50L)
  expect_length(page$data, 5)
  expect_identical(page$data[[1]][[1]], "HMP11")

  page <- response_json(s$post("/api/metadata/table", list(search = list(value = "saliva", regex = FALSE))))
  expect_identical(page$recordsFiltered, 10L)

  expect_identical(s$post("/api/metadata/table", list(order = list(list(column = 99, dir = "asc"))))$status, 400L)

  page <- response_json(s$post("/api/taxonomy/table", list(length = 3)))
  expect_identical(page$recordsTotal, 490L)

  expect_match(response_json(s$post("/api/metadata/thead"))$html, "^<thead><tr><th> .sample </th>")
  expect_match(response_json(s$post("/api/taxonomy/thead"))$html, "<th> Genus </th></tr></thead>$")

  fields <- response_json(s$post("/api/metadata/fields", list(mode = "numeric")))
  expect_identical(vapply(fields$options, function (o) o$value, ""), c("Age", "BMI"))

  expect_identical(unlist(response_json(s$post("/api/metadata/levels", list(field = "Sex")))$default), c("Female", "Male"))
  expect_identical(response_json(s$post("/api/metadata/minmax", list(field = "Age"))), list(min = list(21L), max = list(40L)))
  expect_identical(s$post("/api/metadata/minmax", list(field = "Sex"))$status, 400L)
  expect_identical(s$post("/api/metadata/levels", list(field = "nope"))$status, 400L)
})


test_that("changing a column's class and uploading a component change only the draft", {

  s <- local_open_project()

  # Age (column 2) from numeric to categorical.
  resp <- s$post("/api/metadata/change_class", list(col_num = 2))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$col_types$Age, "cat")
  expect_identical(body$BIOM$depth, 1183L)
  expect_false(body$BIOM$is_saved)
  expect_identical(s$post("/api/metadata/change_class", list(col_num = 99))$status, 400L)

  # Replace the metadata with a file that has a new column.
  md <- rbiom::hmp50$metadata
  md$Batch <- rep(c("A", "B"), 25)
  csv <- withr::local_tempfile(fileext = ".csv")
  utils::write.csv(md, csv, row.names = FALSE)

  form <- multipart_body(list(component = "metadata", component_file = list(filename = "md.csv", value = read_file_raw(csv))))
  resp <- handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_true("Batch" %in% unlist(body$BIOM$cols))
  expect_identical(body$BIOM$depth, 1183L)

  # A file that is not metadata is refused, without naming server paths.
  form <- multipart_body(list(component = "tree", component_file = list(filename = "x.tre", value = charToRaw("not a tree ((("))))
  resp <- suppressWarnings(handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app))
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error$message, "That file could not be read as tree.")

  # The saved project is untouched; the uploads did not pile up.
  hmp50 <- db_query(s$DB, "SELECT meta_colnames FROM projects WHERE access_key = 'hmp50'", "T1")
  expect_no_match(hmp50, "Batch")
  expect_length(list.files(s$temp, pattern = "^upload_"), 1)
})


test_that("an upload becomes a project, and saving copies the draft into it", {

  s <- local_open_project()

  upload <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(rbiom::rarefy(rbiom::hmp50, depth = 1500), upload)
  bytes  <- read_file_raw(upload)

  form <- multipart_body(list(biom_file = list(filename = "my study.biom", value = bytes)))
  resp <- handle_request(fake_request("POST", "/api/project/upload", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 200L)

  body <- response_json(resp)
  expect_identical(body$BIOM$title, "my study")
  expect_true(body$BIOM$is_editor)
  expect_true(body$BIOM$is_saved)
  expect_match(body$jstree_node$id, "^P[0-9]+$")
  expect_identical(body$BIOM$node_id, body$jstree_node$id)

  # The original bytes are stored under their SHA-256.
  project <- db_query(s$DB, "SELECT * FROM projects WHERE title = 'my study'", "T1")
  orig    <- db_query(s$DB, "SELECT file, hash FROM biom_files WHERE biom_file_id = ?", "T2", list(project$orig_bf_id))
  expect_identical(orig$hash, paste(as.character(openssl::sha256(bytes))))
  expect_identical(read_file_raw(file.path(s$REQ$CONFIG$data_dir, "files", orig$file)), bytes)
  expect_identical(project$n_samples, rbiom::rarefy(rbiom::hmp50, depth = 1500)$n_samples)
  expect_false(project$is_public)
  expect_length(list.files(s$temp, pattern = "^upload_"), 0)

  # Something that is not a BIOM file leaves nothing behind in the database.
  form <- multipart_body(list(biom_file = list(filename = "junk.biom", value = charToRaw("this is not a biom file"))))
  resp <- handle_request(fake_request("POST", "/api/project/upload", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error$message, "That file could not be read as a BIOM file.")
  expect_identical(db_query(s$DB, "SELECT COUNT(*) FROM projects", "T3"), 3L)

  # Rarefy the draft, then save: the project takes the draft's files.
  expect_identical(s$post("/api/project/rarefy", list(depth = 1200))$status, 200L)
  resp <- s$post("/api/project/save", list(title = "My study, saved", access_key = "my-study", description = "<p>About</p>"))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM[c("title", "access_key", "is_saved", "depth")], list(title = "My study, saved", access_key = "my-study", is_saved = TRUE, depth = 1200L))

  # Save a copy under another key; a taken key gets a random one instead.
  resp <- s$post("/api/project/save_as", list(title = "A copy", access_key = "hmp50", description = ""))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$title, "A copy")
  expect_false(body$BIOM$access_key %in% c("hmp50", "my-study"))
  expect_identical(db_query(s$DB, "SELECT COUNT(*) FROM projects", "T4"), 4L)
})


test_that("a download is written by a worker and its temporary file removed", {

  s <- local_open_project()

  resp <- handle_request(fake_request("GET", "/hmp50/full.json.gz"), s$app)
  expect_identical(resp$status, 200L)
  expect_identical(resp$body[1:2], as.raw(c(0x1f, 0x8b)))

  expect_length(list.files(file.path(s$REQ$CONFIG$temp_dir, "downloads")), 0)
})
