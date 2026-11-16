# The compute handlers end to end, with real example data: the main-process
# part, the worker function and the finish step. Jobs run in the test
# process here; test-async.R runs the same routes through worker processes.



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
    fn_check_data = forbidden("fn_check_data"),
    biom_inflate = forbidden("biom_inflate"),
    write_xlsx   = forbidden("write_xlsx"),
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
  expect_identical(field_names(s$BIOM), c(".sample", "Age", "BMI", "Body Site", "Sex"))
  expect_identical(s$BIOM$fields[[5]], list(name = "Sex", class = "categorical", levels = list("Female", "Male")))
  expect_identical(s$BIOM$fields[[2]], list(name = "Age", class = "numeric", min = 21L, max = 40L))
  expect_identical(unlist(s$BIOM$ranks), c(".otu", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus"))
  expect_true("Firmicutes" %in% unlist(s$BIOM$taxa$Phylum))

  # Lists that do not depend on the project are in the schema, not here.
  expect_false(any(grepl("_options$", setdiff(names(s$BIOM), "depth_options"))))

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
  expect_identical(body$code$file, "hmp50/rare.hdf5")
  expect_match(body$code$rbiom, "adiv_boxplot")
  expect_match(body$code$ggplot2, "ggplot")

  # So does the figure's caption, as text: the counts and the method.
  expect_match(body$caption, "^Rarefied to 1,183 reads per sample\\.\n[A-Z][^\n]+ tests")

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
  expect_match(response_json(resp)$error$message, "^Argument 'plot_args' is not valid\\. Invalid `x` option")

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


test_that("a caption's lines are broken to fit the image, and returned whole as text", {

  p <- rbiom::bdiv_boxplot(rbiom::rarefy(rbiom::hmp50), stat.by = "Body Site", permutations = 9)

  text <- plot_caption(p)
  expect_match(text, "^Rarefied to 1,183 reads per sample\\.\nPERMANOVA")
  expect_length(strsplit(text, "\n")[[1]], 2L)

  save  <- function (...) check_save_args(list(...))
  lines <- function (p) strsplit(p$labels$caption, "\n", fixed = TRUE)[[1]]

  # Wide enough: as rbiom wrote it.
  expect_identical(fit_captions(p, save(width = 1400, height = 800))$labels$caption, p$labels$caption)

  # Narrower: more lines, the same words, and none wider than the image.
  # The width does not depend on the resolution a screen asks for.
  narrow <- lines(fit_captions(p, save(width = 400, height = 300)))
  expect_gt(length(narrow), 2L)
  expect_identical(paste(narrow, collapse = " "), gsub("\n", " ", p$labels$caption))
  expect_true(all(systemfonts::string_width(narrow, size = 8.8, res = 100) < 400))
  expect_identical(lines(fit_captions(p, save(width = 800, height = 600, dpi = 200))), narrow)
  expect_identical(lines(fit_captions(p, save(width = 4, height = 3, units = "in"))), narrow)

  # A word wider than the image stays whole; a figure without a caption is left alone.
  width <- function (x) nchar(x)
  expect_identical(wrap_line("one two three", 7, width), c("one two", "three"))
  expect_identical(wrap_line("incomprehensibilities and so", 7, width), c("incomprehensibilities", "and so"))
  expect_identical(wrap_line("", 7, width), "")
  q <- p
  q$labels$caption <- NULL
  expect_null(plot_caption(q))
  expect_null(fit_captions(q, save(width = 400, height = 300))$labels$caption)

  # A figure of several panels has a caption under each. Both are fitted,
  # and the text has both.
  m <- rbiom::rare_multiplot(rbiom::hmp50)
  expect_identical(plot_caption(m), paste(sep = "\n",
    "Rarefied to 10 depths, from 5 to 3,577 reads per sample.",
    "Rarefaction depth (dashed line): 1,183 reads per sample." ))
  small <- fit_captions(m, save(width = 200, height = 300))
  expect_match(small$labels$caption, "\n", fixed = TRUE)
  expect_match(small$patches$plots[[1]]$labels$caption, "\n", fixed = TRUE)
})


test_that("every plot atima offers has a caption, and an NMDS states its stress", {

  s <- local_open_project()

  args <- list(
    adiv_corrplot = list(x = "Age"), bdiv_corrplot = list(x = "Age"), taxa_corrplot = list(x = "Age"),
    bdiv_boxplot  = list(stat.by = "Sex", permutations = 9),
    bdiv_ord_plot = list(ord = "NMDS", stat.by = "Sex", permutations = 9),
    taxa_forest   = list(stat.by = "Sex"),
    taxa_upset    = list(stat.by = "Body Site") )

  # rbiom (at d90e979) writes no caption under an UpSet plot. The page then
  # says under the figure what it was made from (`madeFrom()` in plot.js).
  uncaptioned <- "taxa_upset"

  captions <- list()

  for (fn in schema_fns("plot")) {
    resp <- s$post("/api/plot", list(plot_fn = fn, plot_args = args[[fn]] %||% list(), depth = 1183, attrs = TRUE))
    expect_identical(resp$status, 200L, info = fn)
    captions[[fn]] <- response_json(resp)$caption
    if (fn %in% uncaptioned) next
    expect_true(is_scalar_character(captions[[fn]]) && nzchar(captions[[fn]]), info = fn)
  }

  # What the line under the figure used to say is in the caption now.
  expect_match(captions$adiv_boxplot, "Rarefied to 1,183 reads per sample.", fixed = TRUE)
  expect_match(captions$taxa_forest,  "^Unrarefied counts \\(182 to 22,117 reads per sample\\)\\.\nLinDA")
  expect_match(captions$bdiv_ord_plot, "\nNMDS stress = 0\\.[0-9]+\\.\n")
  expect_match(captions$rare_stacked, "Rarefaction depth")
})


test_that("a figure and a table come with methods text that says what atima did", {

  s <- local_open_project()

  resp <- s$post("/api/plot", list(
    plot_fn     = "adiv_boxplot",
    plot_args   = list(x = "Body Site", adiv = "Shannon"),
    depth       = 1183,
    attrs       = TRUE,
    subset_args = list(cat = list(`Body Site` = c("Saliva", "Stool")), num = list(Age = c(20, 40))) ))
  expect_identical(resp$status, 200L)
  methods <- response_json(resp)$methods
  text    <- methods$text

  # How the counts were rarefied and filtered, in that order, then the data
  # the figure was made from, the method, and the software.
  expect_match(text, paste0(
    "^Samples were rarefied to 1,183 reads per sample \\(random seed 0\\); samples with fewer reads were excluded\\. ",
    "Samples were restricted to those whose Body Site was Saliva or Stool and whose Age was from 20 to 40\\. ",
    "The analyzed dataset comprised [0-9]+ samples and [0-9,]+ OTUs\\. ",
    "Alpha diversity was measured with the Shannon diversity index \\(Shannon 1948\\)\\." ))
  expect_match(text, "Wilcoxon rank-sum (Mann-Whitney U) tests", fixed = TRUE)
  expect_match(text, sprintf("Analyses were performed with rbiom %s in R ", utils::packageVersion("rbiom")), fixed = TRUE)
  expect_match(text, sprintf("The analyses were run through ATIMA %s (Smith ", utils::packageVersion("atima")), fixed = TRUE)

  # Nothing of the stored file: not its name, not a path on the server.
  expect_no_match(text, "imported|\\.biom|\\.h5|hdf5|atima_sample_filter|[/\\\\]")

  # The references, in order, with ATIMA's as the "How to cite" page has it.
  refs <- unlist(methods$references)
  expect_identical(refs, refs[order(tolower(refs), method = "radix")])
  expect_true(any(startsWith(refs, "Wilcoxon F (1945).")))
  expect_true(any(startsWith(refs, "Shannon CE (1948).")))
  expect_true(atima_reference() %in% refs)

  # A figure made from all reads says so, and nothing about rarefying.
  resp <- s$post("/api/plot", list(plot_fn = "rare_stacked", plot_args = list(), depth = 1183, attrs = TRUE))
  expect_identical(resp$status, 200L)
  text <- response_json(resp)$methods$text
  expect_match(text, "^The analyzed dataset comprised 50 samples and 490 OTUs\\. The abundance table held unrarefied counts")
  expect_no_match(text, "were rarefied to|restricted")

  # Without `attrs` there is no text, as there is no code.
  resp <- s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1183))
  expect_identical(resp$status, 200L)
  expect_null(response_json(resp)$methods)

  # A table's page has it too.
  resp <- s$post("/api/table", list(table_fn = "taxa_top", table_args = list(rank = "Phylum", n = 3), depth = 1183,
    subset_args = list(cat = list(Sex = "Female"))))
  expect_identical(resp$status, 200L)
  text <- response_json(resp)$methods$text
  expect_match(text, "^Samples were rarefied to 1,183 reads per sample .*Samples were restricted to those whose Sex was Female\\. ")
  expect_match(text, "Counts were summarized at the Phylum rank", fixed = TRUE)
  expect_match(text, "the 3 most abundant were listed", fixed = TRUE)
})


test_that("the sentence for the sample filter names what was kept", {

  expect_identical(
    filter_sentence(list(cat = list(Sex = "Male"))),
    "Samples were restricted to those whose Sex was Male." )
  expect_identical(
    filter_sentence(list(cat = list(`Body Site` = c("Saliva", "Stool", "Anterior nares")), num = list(Age = c(20.5, 1e6)))),
    "Samples were restricted to those whose Body Site was Saliva, Stool, or Anterior nares and whose Age was from 20.5 to 1000000." )
  expect_identical(
    filter_sentence(list(cat = list(.sample = c("A", "B"), Sex = "Female"), num = list(Age = c(1, 2), BMI = c(18, 25)))),
    "Samples were restricted to those named A or B, whose Sex was Female, whose Age was from 1 to 2, and whose BMI was from 18 to 25." )

  # Long lists are counted, not listed.
  expect_identical(
    filter_sentence(list(cat = list(.sample = LETTERS[1:6], Site = letters[1:11]))),
    "Samples were restricted to those that were among 6 samples chosen by name and whose Site was one of 11 chosen values." )
})


test_that("methods text comes from what rbiom writes, and never stops a result", {

  b <- rbiom::rarefy(rbiom::hmp50)

  # rbiom's sentence for a step it does not know is how the filter's
  # sentence finds its place. If rbiom words it differently, whatever it
  # wrote about the placeholder is left out and the filter's sentence goes
  # first.
  p <- rbiom::bdiv_heatmap(b)
  m <- result_methods(p, b$depth, list(cat = list(Sex = "Male")))
  expect_match(m$text, "per sample (random seed 0); samples with fewer reads were excluded. Samples were restricted to those whose Sex was Male. The analyzed", fixed = TRUE)

  local_mocked_bindings(methods_filter_sentence = "Nothing rbiom writes.")
  m <- result_methods(p, b$depth, list(cat = list(Sex = "Male")))
  expect_match(m$text, "^Samples were restricted to those whose Sex was Male\\. Samples were rarefied")
  expect_no_match(m$text, "atima_sample_filter", fixed = TRUE)
  expect_match(m$text, "were excluded. The analyzed dataset", fixed = TRUE)

  # Something rbiom has no text for gives none, without an error.
  expect_null(result_methods(list(a = 1)))
  expect_null(result_methods(NULL))
  expect_null(methods_reply(NULL))
  expect_null(methods_data(NULL))
})


test_that("exports are written once, atomically, under names that say what is inside", {

  s <- local_open_project()

  full <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")
  rare <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T2")
  orig <- db_query(s$DB, "SELECT orig_bf_id FROM projects WHERE public_key = 'hmp50'", "T3")

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

  # The field lists the old controls asked for one at a time are part of
  # the project summary now, and their routes are gone.
  for (gone in c("fields", "levels", "minmax"))
    expect_identical(s$post(paste0("/api/metadata/", gone), list(field = "Sex"))$status, 404L)
})


test_that("changing a column's class and uploading a component change only the draft", {

  s <- local_open_project()

  # Age (column 2) from numeric to categorical.
  resp <- s$post("/api/metadata/change_class", list(col_num = 2))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$fields[[2]][c("name", "class")], list(name = "Age", class = "categorical"))
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
  expect_true("Batch" %in% field_names(body$BIOM))
  expect_identical(body$BIOM$depth, 1183L)

  # A file that is not a tree is refused with the reason, without naming
  # server paths (more in test-import.R).
  form <- multipart_body(list(component = "tree", component_file = list(filename = "x.tre", value = charToRaw("not a tree ((("))))
  resp <- suppressWarnings(handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app))
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "^That file could not be used as the project's tree\\.\nCan't parse 'x.tre' as a Newick tree\\.")
  expect_match(response_json(resp)$error$message, "\nThe tree was not changed\\.$")
  expect_no_server_path(resp$body)

  # The saved project is untouched; no upload was left behind.
  hmp50 <- db_query(s$DB, "SELECT meta_colnames FROM projects WHERE public_key = 'hmp50'", "T1")
  expect_no_match(hmp50, "Batch")
  expect_length(list.files(s$temp, pattern = "^upload_"), 0)
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
  expect_match(body$tree_node$id, "^P[0-9]+$")
  expect_identical(body$BIOM$node_id, body$tree_node$id)

  # The original bytes are stored under their SHA-256.
  project <- db_query(s$DB, "SELECT * FROM projects WHERE title = 'my study'", "T1")
  orig    <- db_query(s$DB, "SELECT file, hash FROM biom_files WHERE biom_file_id = ?", "T2", list(project$orig_bf_id))
  expect_identical(orig$hash, paste(as.character(openssl::sha256(bytes))))
  expect_identical(read_file_raw(file.path(s$REQ$CONFIG$data_dir, "files", orig$file)), bytes)
  expect_identical(project$n_samples, rbiom::rarefy(rbiom::hmp50, depth = 1500)$n_samples)
  expect_true(is.na(project$public_key))
  expect_match(project$access_key, "^[a-z0-9]{12}$")
  expect_length(list.files(s$temp, pattern = "^upload_"), 0)

  # Something that is not a BIOM file leaves nothing behind in the database.
  form <- multipart_body(list(biom_file = list(filename = "junk.biom", value = charToRaw("this is not a biom file"))))
  resp <- handle_request(fake_request("POST", "/api/project/upload", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error$message, "This file could not be imported.\nNo abundance counts in 'junk.biom'.")
  expect_identical(db_query(s$DB, "SELECT COUNT(*) FROM projects", "T3"), 3L)
  expect_length(list.files(s$temp, pattern = "^upload_"), 0)

  # Rarefy the draft, then save: the project takes the draft's files.
  expect_identical(s$post("/api/project/rarefy", list(depth = 1200))$status, 200L)
  resp <- s$post("/api/project/save", list(title = "My study, saved", description = "<p>About</p>"))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(
    body$BIOM[c("title", "description", "access_key", "is_saved", "depth")],
    list(title = "My study, saved", description = "<p>About</p>", access_key = project$access_key, is_saved = TRUE, depth = 1200L) )

  # Nobody chooses a private key: a request that tries is refused.
  resp <- s$post("/api/project/save", list(title = "My study", access_key = "easy", description = ""))
  expect_identical(resp$status, 400L)

  # A copy is a new private project with a random key of its own.
  resp <- s$post("/api/project/save_as", list(title = "A copy", description = ""))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$title, "A copy")
  expect_match(body$BIOM$access_key, "^[a-z0-9]{12}$")
  expect_false(identical(body$BIOM$access_key, project$access_key))
  expect_false(body$BIOM$is_public)
  expect_identical(db_query(s$DB, "SELECT COUNT(*) FROM projects", "T4"), 4L)

  # Found in the browser (step 7): the copy's creation date was stored as a
  # number, and from then on its owner's project tree, and with it every
  # page load, failed. The date is text, and it is the copy's own.
  dates <- DBI::dbGetQuery(s$DB, "SELECT typeof(created_utc) AS type, created_utc FROM projects ORDER BY project_id")
  expect_identical(unique(dates$type), "text")
  expect_match(dates$created_utc, "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")

  # A copy of the copy, then a new tab: the tree lists all three.
  expect_identical(s$post("/api/project/save_as", list(title = "A second copy", description = ""))$status, 200L)
  resp <- handle_request(fake_request("POST", "/api/session/init", list(), session = s$session), s$app)
  expect_identical(resp$status, 200L)
  expect_setequal(
    vapply(response_json(resp)$tree$private, function (node) node$text, ""),
    c("My study, saved", "A copy", "A second copy") )
})


test_that("the order of a field's levels is set on the draft, kept, and followed by figures", {

  s     <- local_open_project()
  files <- function () db_query(s$DB, paste(
    "SELECT drafts.full_bf_id AS full, drafts.rare_bf_id AS rare",
    "FROM sessions JOIN drafts USING (draft_id) WHERE session_key = ?"), "T1", list(s$session$session_key))
  stored <- function (id) rbiom::as_rbiom(biom_path(s$REQ, id))   # from the file, not the cache
  levels_of <- function (BIOM, name) unlist(Filter(function (f) f$name == name, BIOM$fields)[[1]]$levels)
  axis <- function (biom) {
    p <- rbiom::adiv_boxplot(biom, x = "Body Site", adiv = "Shannon")
    ggplot2::ggplot_build(p)$layout$panel_params[[1]]$x$get_labels()
  }

  alphabet <- c("Anterior nares", "Buccal mucosa", "Mid vagina", "Saliva", "Stool")
  wanted   <- c("Stool", "Saliva", "Anterior nares", "Buccal mucosa", "Mid vagina")
  expect_identical(levels_of(s$BIOM, "Body Site"), alphabet)
  expect_identical(axis(stored(files()$rare)), alphabet)

  # Values left out follow the ones given, in their old order.
  resp <- s$post("/api/metadata/level_order", list(field = "Body Site", levels = list("Stool", "Saliva")))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(levels_of(body$BIOM, "Body Site"), wanted)
  expect_false(body$BIOM$is_saved)

  # Both files are HDF5 and have the order: the rarefied one is what most
  # figures are drawn from, and its axis follows.
  for (id in files()) {
    expect_identical(readBin(biom_path(s$REQ, id), "raw", 4), as.raw(c(0x89, 0x48, 0x44, 0x46)))
    expect_identical(levels(stored(id)$metadata$`Body Site`), wanted)
  }
  expect_identical(axis(stored(files()$rare)), wanted)

  # The R code beside a figure downloads HDF5, which keeps the order.
  resp <- handle_request(fake_request("GET", paste0("/unsaved/", s$session$session_key, "/rare.hdf5")), s$app)
  expect_identical(resp$status, 200L)
  download <- withr::local_tempfile(fileext = ".hdf5")
  writeBin(resp$body, download)
  expect_identical(levels(rbiom::as_rbiom(download)$metadata$`Body Site`), wanted)

  # Rarefied to another depth, and saved as a copy: still in order. The
  # summary is computed again from the files, with atima's cache emptied.
  expect_identical(s$post("/api/project/rarefy", list(depth = 1000))$status, 200L)
  body <- response_json(s$post("/api/project/save_as", list(title = "Ordered copy", description = "")))
  expect_identical(levels_of(body$BIOM, "Body Site"), wanted)
  unlink(file.path(s$REQ$CONFIG$data_dir, "cache"), recursive = TRUE)
  copy <- db_query(s$DB, "SELECT full_bf_id, rare_bf_id FROM projects WHERE title = 'Ordered copy'", "T2")
  data <- work_summary(worker_ctx(s$REQ$CONFIG), biom_path(s$REQ, copy$full_bf_id), biom_path(s$REQ, copy$rare_bf_id))$data
  expect_identical(levels_of(data, "Body Site"), wanted)
  expect_identical(as.integer(data$depth), 1000L)

  # Refused: a numeric field, a value the field does not have, the order it
  # has already, a field that does not exist.
  refused <- function (args, message) {
    resp <- s$post("/api/metadata/level_order", args)
    expect_identical(resp$status, 400L)
    expect_match(response_json(resp)$error$message, message)
  }
  refused(list(field = "Age", levels = list("21")), "is numeric")
  refused(list(field = "Body Site", levels = list("Stool", "Gut")), "has no value 'Gut'")
  refused(list(field = "Body Site", levels = as.list(wanted)), "in this order already")
  refused(list(field = "Nope", levels = list("a")), "no metadata field called 'Nope'")
  refused(list(field = ".sample", levels = list("HMP01")), "no metadata field called")

  # A field of numbers made categorical has its values in the order of
  # the numbers, not of the alphabet.
  body <- response_json(s$post("/api/metadata/change_class", list(col_num = 2)))
  ages <- levels_of(body$BIOM, "Age")
  expect_identical(ages, as.character(sort(as.numeric(ages))))
  expect_identical(levels(as_categories(c(10, 2, 2.5, NA, 1, 10))), c("1", "2", "2.5", "10"))
})


test_that("the groups of a field get colors, kept with the project and used by every figure", {

  s     <- local_open_project()
  ctx   <- worker_ctx(s$REQ$CONFIG)
  files <- function () db_query(s$DB, paste(
    "SELECT drafts.full_bf_id AS full, drafts.rare_bf_id AS rare",
    "FROM sessions JOIN drafts USING (draft_id) WHERE session_key = ?"), "T1", list(s$session$session_key))
  colors_of <- function (BIOM, name) unlist(Filter(function (f) f$name == name, BIOM$fields)[[1]]$colors)
  plot_code <- function (fn, args) {
    resp <- s$post("/api/plot", list(plot_fn = fn, plot_args = args, depth = 1183, attrs = TRUE))
    expect_identical(resp$status, 200L)
    response_json(resp)$code$rbiom
  }

  # Nothing chosen: rbiom's defaults, and the summary has no colors.
  expect_null(colors_of(s$BIOM, "Sex"))
  expect_false(grepl("colors", plot_code("adiv_boxplot", list(x = "Sex"))))

  resp <- s$post("/api/metadata/colors", list(field = "Sex", colors = list(Male = "steelblue", Female = "#d95f02")))
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(colors_of(body$BIOM, "Sex"), c(Female = "#D95F02", Male = "#4682B4"))
  expect_false(body$BIOM$is_saved)

  # Both files of the draft keep them.
  for (id in files()) expect_identical(read_colors(biom_path(s$REQ, id))$Sex, c(Female = "#D95F02", Male = "#4682B4"))

  # Figures colored by the field use them, and their R code has them; a
  # figure's own choice comes first.
  sex <- "colors = c('Female' = \"#D95F02\", 'Male' = \"#4682B4\")"
  expect_match(plot_code("adiv_boxplot", list(x = "Sex")), sex, fixed = TRUE)
  expect_match(plot_code("bdiv_ord_plot", list(stat.by = "Sex")), sex, fixed = TRUE)
  expect_match(plot_code("bdiv_boxplot", list(x = "Sex")), sex, fixed = TRUE)
  expect_match(plot_code("taxa_heatmap", list(tracks = list("Sex", "Age"))), "tracks = list(Sex = c(", fixed = TRUE)
  expect_match(plot_code("adiv_boxplot", list(x = "Sex", colors = "bright")), 'colors = "bright"', fixed = TRUE)
  expect_false(grepl("4682B4", plot_code("adiv_boxplot", list(x = "Body Site"))))

  # Groups left out keep their colors; another order of the levels keeps
  # each group's color; so do rarefying and saving a copy.
  body <- response_json(s$post("/api/metadata/colors", list(field = "Sex", colors = list(Male = "black"))))
  expect_identical(colors_of(body$BIOM, "Sex"), c(Female = "#D95F02", Male = "#000000"))
  body <- response_json(s$post("/api/metadata/level_order", list(field = "Sex", levels = list("Male"))))
  expect_identical(colors_of(body$BIOM, "Sex"), c(Male = "#000000", Female = "#D95F02"))
  expect_match(plot_code("adiv_boxplot", list(x = "Sex")), "colors = c('Male' = \"#000000\", 'Female' = \"#D95F02\")", fixed = TRUE)
  body <- response_json(s$post("/api/project/rarefy", list(depth = 1000)))
  expect_identical(colors_of(body$BIOM, "Sex"), c(Male = "#000000", Female = "#D95F02"))
  body <- response_json(s$post("/api/metadata/change_class", list(col_num = 3)))
  expect_identical(colors_of(body$BIOM, "Sex"), c(Male = "#000000", Female = "#D95F02"))
  body <- response_json(s$post("/api/project/save_as", list(title = "Colored copy", description = "")))
  expect_identical(colors_of(body$BIOM, "Sex"), c(Male = "#000000", Female = "#D95F02"))
  unlink(file.path(s$REQ$CONFIG$data_dir, "cache"), recursive = TRUE)
  copy <- db_query(s$DB, "SELECT full_bf_id, rare_bf_id FROM projects WHERE title = 'Colored copy'", "T2")
  data <- work_summary(ctx, biom_path(s$REQ, copy$full_bf_id), biom_path(s$REQ, copy$rare_bf_id))$data
  expect_identical(colors_of(data, "Sex"), c(Male = "#000000", Female = "#D95F02"))

  # An HDF5 download has them, and a new project uploaded from it.
  resp <- handle_request(fake_request("GET", paste0("/unsaved/", s$session$session_key, "/full.hdf5")), s$app)
  download <- withr::local_tempfile(fileext = ".hdf5")
  writeBin(resp$body, download)
  expect_identical(read_colors(download)$Sex[c("Male", "Female")], c(Male = "#000000", Female = "#D95F02"))
  imported <- work_import(ctx, download)
  expect_identical(colors_of(imported$data, "Sex"), c(Male = "#000000", Female = "#D95F02"))

  # Reset: back to rbiom's defaults.
  body <- response_json(s$post("/api/metadata/colors", list(field = "Sex", reset = TRUE)))
  expect_null(colors_of(body$BIOM, "Sex"))
  expect_false(grepl("colors", plot_code("adiv_boxplot", list(x = "Sex"))))

  refused <- function (args, message) {
    resp <- s$post("/api/metadata/colors", args)
    expect_identical(resp$status, 400L)
    expect_match(response_json(resp)$error$message, message)
  }
  refused(list(field = "Sex", reset = TRUE), "no colors of their own to remove")
  refused(list(field = "Sex"), "Give a color for at least one group")
  refused(list(field = "Sex", colors = list(Male = "nope")), "neither a hex code")
  refused(list(field = "Sex", colors = list(Other = "red")), "has no value 'Other'")
  refused(list(field = "Age", colors = list(`30` = "red")), "is numeric")
  refused(list(field = "Nope", colors = list(a = "red")), "no metadata field called 'Nope'")
})


test_that("a project stored as JSON by atima 5 still opens, and is stored as HDF5 when it changes", {

  s    <- local_open_project()
  ctx  <- worker_ctx(s$REQ$CONFIG)
  hmp  <- db_query(s$DB, "SELECT project_id, full_bf_id, rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")

  # The project's files rewritten as atima 5 wrote them.
  as_json <- function (id) {
    tfile <- withr::local_tempfile(fileext = ".json.bz2", .local_envir = parent.frame(2))
    rbiom::write_biom(rbiom::as_rbiom(biom_path(s$REQ, id)), tfile, format = "json")
    register_biom_file(s$DB, store_file(ctx$files_dir, tfile))
  }
  full <- as_json(hmp$full_bf_id)
  rare <- as_json(hmp$rare_bf_id)
  DBI::dbExecute(s$DB, "UPDATE projects SET full_bf_id = ?, rare_bf_id = ? WHERE project_id = ?", list(full, rare, hmp$project_id))
  DBI::dbExecute(s$DB, "UPDATE drafts SET full_bf_id = ?, rare_bf_id = ? WHERE project_id = ?", list(full, rare, hmp$project_id))
  expect_identical(rawToChar(readBin(biom_path(s$REQ, full), "raw", 3)), "BZh")

  # It opens, its tables and figures work, and it downloads.
  resp <- handle_request(fake_request("POST", "/api/session/init", list(), session = s$session), s$app)
  expect_identical(response_json(resp)$BIOM$depth, 1183L)
  expect_identical(s$post("/api/metadata/table")$status, 200L)
  expect_identical(s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Sex"), depth = 1183))$status, 200L)
  expect_identical(handle_request(fake_request("GET", "/hmp50/full.hdf5"), s$app)$status, 200L)

  # A change writes HDF5, and the order of levels is kept from then on.
  resp <- s$post("/api/metadata/level_order", list(field = "Sex", levels = list("Male")))
  expect_identical(resp$status, 200L)
  draft <- db_query(s$DB, paste(
    "SELECT drafts.full_bf_id, drafts.rare_bf_id",
    "FROM sessions JOIN drafts USING (draft_id) WHERE session_key = ?"), "T2", list(s$session$session_key))
  for (id in unlist(draft)) {
    expect_identical(readBin(biom_path(s$REQ, id), "raw", 4), as.raw(c(0x89, 0x48, 0x44, 0x46)))
    expect_identical(levels(rbiom::as_rbiom(biom_path(s$REQ, id))$metadata$Sex), c("Male", "Female"))
  }
})


test_that("a download is written by a worker and its temporary file removed", {

  s <- local_open_project()

  resp <- handle_request(fake_request("GET", "/hmp50/full.json.gz"), s$app)
  expect_identical(resp$status, 200L)
  expect_identical(resp$body[1:2], as.raw(c(0x1f, 0x8b)))

  expect_length(list.files(file.path(s$REQ$CONFIG$temp_dir, "downloads")), 0)
})


test_that("a project's title comes from the uploaded file's name", {

  # Found in the browser (step 7): "fractions.tsv" kept its ".tsv".
  expect_identical(upload_title("gut study.biom"), "gut study")
  expect_identical(upload_title("data/gut study.biom.gz"), "gut study")
  expect_identical(upload_title("/home/me/counts.TSV"), "counts")
  expect_identical(upload_title("table.json.bz2"), "table")
  expect_identical(upload_title("v1.2 final"), "v1.2 final")
  expect_identical(upload_title("feature-table.qza"), "feature-table")
  expect_identical(upload_title("stability.opti_mcc.shared"), "stability.opti_mcc")
  expect_identical(nchar(upload_title(paste0(strrep("a", 150), ".biom"))), 100L)
})
