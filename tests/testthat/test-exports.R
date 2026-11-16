# Downloads for other programs: QIIME 2 and mothur (a zip of text files) and
# phyloseq (an .rds file). Each is made through the route or the MCP tool,
# then opened and read back.


# The files of a zip, extracted into a directory of their own.
local_unzip <- function (zipfile, env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  zip::unzip(zipfile, exdir = dir)
  dir
}

local_export <- function (s) {
  function (...) {
    resp <- s$post("/api/project/export", list(...))
    expect_identical(resp$status, 200L)
    url <- response_json(resp)$download_url
    list(url = url, file = file.path(s$REQ$CONFIG$temp_dir, sub("^/tmp/", "", url)))
  }
}

counts_of <- function (biom) {
  m <- as.matrix(biom$counts)
  m[order(rownames(m)), order(colnames(m)), drop = FALSE]
}


test_that("the exports a server offers are those it has the packages for", {

  forget <- function () rm(list = ls(schema_env), envir = schema_env)
  forget()
  withr::defer(forget())

  local_mocked_bindings(has_package = function (pkg) TRUE)
  expect_identical(export_choices(), export_whats)
  forget()

  local_mocked_bindings(has_package = function (pkg) !any(as.character(unlist(pkg)) %in% "phyloseq"))
  expect_identical(export_choices(), setdiff(export_whats, "phyloseq"))
  expect_false("phyloseq" %in% unlist(fromJSON(browser_schema_json(), simplifyVector = FALSE)$exports))
  forget()

  local_mocked_bindings(has_package = function (pkg) !any(as.character(unlist(pkg)) %in% c("zip", "openxlsx")))
  expect_identical(export_choices(), setdiff(export_whats, c("xlsx", "qiime2", "mothur")))

  # The browser is told, and so is an AI app.
  expect_identical(
    unlist(fromJSON(browser_schema_json(), simplifyVector = FALSE)$exports),
    setdiff(export_whats, c("xlsx", "qiime2", "mothur")) )

  tools <- mcp_tool_table()
  names(tools) <- vapply(tools, function (t) t[['name']], character(1))
  expect_identical(
    unlist(tool_definition(tools[["export"]])$inputSchema$properties$what$enum),
    c("biom", "metadata", "taxonomy", "tree", "alpha", "beta", "taxa", "phyloseq") )
})


test_that("an export that needs a missing package is refused without a worker", {

  s <- local_open_project()

  forget <- function () rm(list = ls(schema_env), envir = schema_env)
  forget()
  withr::defer(forget())

  local_mocked_bindings(
    has_package = function (pkg) !any(as.character(unlist(pkg)) %in% c("zip", "phyloseq")),
    worker_run  = function (...) stop("a worker was used") )

  for (what in c("qiime2", "mothur")) {
    resp <- s$post("/api/project/export", list(what = what))
    expect_identical(resp$status, 400L)
    expect_identical(response_json(resp)$error$message, "This server cannot make zip files: the zip package is not installed.")
  }

  resp <- s$post("/api/project/export", list(what = "phyloseq"))
  expect_identical(resp$status, 400L)
  expect_identical(response_json(resp)$error$message, "This server cannot make phyloseq files: the phyloseq package is not installed.")
})


test_that("a project is exported for QIIME 2 as a zip of files that read back", {

  skip_if_not_installed("zip")

  s      <- local_open_project()
  export <- local_export(s)

  full <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")
  rare <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T2")

  out <- export(what = "qiime2")
  expect_identical(out$url, sprintf("/tmp/%s/%i/qiime2_full_%i.zip", s$session$session_key, full, full))

  # A zip file, with the files at its top level.
  expect_identical(readBin(out$file, "raw", 4), as.raw(c(0x50, 0x4b, 0x03, 0x04)))
  dir <- local_unzip(out$file)
  expect_setequal(list.files(dir, recursive = TRUE), paste0("qiime2_", c(
    "README.txt", "counts.tsv", "metadata.tsv", "taxonomy.tsv", "tree.nwk" )))

  hmp50 <- rbiom::hmp50

  # rbiom reads the counts back as they were.
  counts <- rbiom::read_biom(file.path(dir, "qiime2_counts.tsv"))
  expect_identical(counts_of(counts), counts_of(hmp50))

  # The metadata says which columns are numbers.
  md <- readLines(file.path(dir, "qiime2_metadata.tsv"))
  expect_identical(md[[1]], "sample-id\tAge\tBMI\t\"Body Site\"\tSex")
  expect_identical(md[[2]], "#q2:types\tnumeric\tnumeric\tcategorical\tcategorical")
  expect_length(md, 52)

  tax <- utils::read.delim(file.path(dir, "qiime2_taxonomy.tsv"), check.names = FALSE)
  expect_identical(colnames(tax), c("Feature ID", "Taxon", "Confidence"))
  expect_setequal(tax[["Feature ID"]], hmp50$otus)
  expect_match(tax[["Taxon"]][[1]], "Bacteria;.*Firmicutes")

  tree <- rbiom::read_tree(file.path(dir, "qiime2_tree.nwk"))
  expect_setequal(tree$tip.label, hmp50$otus)

  # (No sequences: atima does not keep them when a project is uploaded.)

  # The note names each file and how to import it.
  readme <- readLines(file.path(dir, "qiime2_README.txt"))
  expect_match(readme[[1]], "files for QIIME 2$")
  for (file in setdiff(list.files(dir), "qiime2_README.txt"))
    expect_true(any(startsWith(readme, file)), info = file)
  expect_identical(sum(grepl("qiime tools import", readme, fixed = TRUE)), 3L)

  # Rarefied: every sample at the project's depth.
  out <- export(what = "qiime2", sample_set = "rare")
  expect_identical(out$url, sprintf("/tmp/%s/%i/qiime2_rare_%i.zip", s$session$session_key, rare, rare))
  counts <- rbiom::read_biom(file.path(local_unzip(out$file), "qiime2_counts.tsv"))
  expect_true(all(rbiom::sample_sums(counts) == 1183))
  expect_identical(counts$n_samples, 49L)

  # Nothing half-written is left, and a second request needs no worker.
  expect_length(list.files(s$temp, pattern = "\\.tmp$", recursive = TRUE), 0)
  local_mocked_bindings(worker_run = function (...) stop("a worker was used"))
  expect_identical(export(what = "qiime2")$url, sprintf("/tmp/%s/%i/qiime2_full_%i.zip", s$session$session_key, full, full))
})


test_that("a project is exported for mothur as a zip of files that read back", {

  skip_if_not_installed("zip")

  s      <- local_open_project()
  export <- local_export(s)
  full   <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")

  out <- export(what = "mothur")
  expect_identical(out$url, sprintf("/tmp/%s/%i/mothur_full_%i.zip", s$session$session_key, full, full))

  dir <- local_unzip(out$file)
  expect_setequal(list.files(dir, recursive = TRUE), paste0("mothur_", c(
    "README.txt", "counts.tsv", "metadata.tsv", "taxonomy.tsv", "tree.nwk" )))

  hmp50 <- rbiom::hmp50
  want  <- counts_of(hmp50)

  # A count table: the OTU, its total, then each sample.
  counts <- utils::read.delim(file.path(dir, "mothur_counts.tsv"), check.names = FALSE)
  expect_identical(colnames(counts)[1:2], c("Representative_Sequence", "total"))
  got <- as.matrix(counts[, -(1:2)])
  rownames(got) <- counts[[1]]
  got <- got[order(rownames(got)), order(colnames(got))]
  expect_equal(got, want, ignore_attr = TRUE)
  expect_identical(dimnames(got), dimnames(want))
  expect_equal(counts[["total"]], unname(rowSums(as.matrix(counts[, -(1:2)]))))

  tax <- utils::read.delim(file.path(dir, "mothur_taxonomy.tsv"))
  expect_identical(colnames(tax), c("OTU", "Size", "Taxonomy"))
  expect_setequal(tax$OTU, hmp50$otus)
  expect_true(all(endsWith(tax$Taxonomy, ";")))
  expect_identical(tax$Size[match(rownames(want), tax$OTU)], as.integer(rowSums(want)))

  md <- utils::read.delim(file.path(dir, "mothur_metadata.tsv"))
  expect_identical(colnames(md), c("group", "Age", "BMI", "Body_Site", "Sex"))
  expect_setequal(md$group, hmp50$samples)

  expect_setequal(rbiom::read_tree(file.path(dir, "mothur_tree.nwk"))$tip.label, hmp50$otus)

  # The note has no QIIME 2 commands.
  readme <- readLines(file.path(dir, "mothur_README.txt"))
  expect_match(readme[[1]], "files for mothur$")
  expect_false(any(grepl("qiime", readme, fixed = TRUE)))
})


test_that("a zip holds only what the project has", {

  skip_if_not_installed("zip")

  bare <- rbiom::as_rbiom(list(counts = as.matrix(rbiom::hmp50$counts)[1:20, 1:5]))
  expect_null(bare$tree)

  for (kind in c("qiime2", "mothur")) {

    file <- withr::local_tempfile(fileext = ".tmp")
    export_zip(bare, file, kind, "Counts only")

    dir <- local_unzip(file)
    expect_setequal(list.files(dir), paste0(kind, c("_README.txt", "_counts.tsv")))

    readme <- readLines(file.path(dir, paste0(kind, "_README.txt")))
    expect_identical(readme[[1]], paste0("Counts only: files for ", if (kind == "qiime2") "QIIME 2" else "mothur"))
    expect_false(any(grepl("taxonomy|tree|seqs|metadata\\.tsv", readme)))
  }

  # Sequences are written when the data has them.
  file <- withr::local_tempfile(fileext = ".tmp")
  export_zip(rbiom::hmp50, file, "qiime2", "With sequences")
  dir  <- local_unzip(file)
  seqs <- readLines(file.path(dir, "qiime2_seqs.fna"))
  expect_identical(sum(startsWith(seqs, ">")), rbiom::hmp50$n_otus)
  expect_identical(sum(grepl("qiime tools import", readLines(file.path(dir, "qiime2_README.txt")), fixed = TRUE)), 4L)

  # A title in another script is written as UTF-8.
  file <- withr::local_tempfile(fileext = ".tmp")
  export_zip(bare, file, "mothur", "Café 微生物")
  readme <- readLines(file.path(local_unzip(file), "mothur_README.txt"), encoding = "UTF-8")
  expect_identical(readme[[1]], "Café 微生物: files for mothur")
})


test_that("a project is exported as a phyloseq object", {

  skip_if_not_installed("phyloseq")

  s      <- local_open_project()
  export <- local_export(s)
  rare   <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")

  out <- export(what = "phyloseq", sample_set = "rare")
  expect_identical(out$url, sprintf("/tmp/%s/%i/phyloseq_rare_%i.rds", s$session$session_key, rare, rare))

  physeq <- readRDS(out$file)
  expect_s4_class(physeq, "phyloseq")

  want <- rbiom::rarefy(rbiom::hmp50, depth = 1183)
  expect_identical(phyloseq::nsamples(physeq), want$n_samples)
  expect_identical(phyloseq::ntaxa(physeq), want$n_otus)
  expect_true(all(phyloseq::sample_sums(physeq) == 1183))
  expect_identical(phyloseq::rank_names(physeq), setdiff(want$ranks, ".otu"))
  expect_identical(phyloseq::sample_variables(physeq), setdiff(want$fields, ".sample"))
  expect_setequal(phyloseq::phy_tree(physeq)$tip.label, want$otus)

  # All reads, by default.
  physeq <- readRDS(export(what = "phyloseq")$file)
  got    <- as(phyloseq::otu_table(physeq), "matrix")
  expect_identical(got[order(rownames(got)), order(colnames(got))], counts_of(rbiom::hmp50))

  expect_length(list.files(s$temp, pattern = "\\.tmp$", recursive = TRUE), 0)
})


test_that("the MCP export tool makes the same files", {

  skip_if_not_installed("zip")

  mcp <- local_mcp()

  data <- mcp$call("export", list(project = "hmp50", what = "qiime2"))$structuredContent
  expect_identical(data[c("what", "counts", "file")], list(what = "qiime2", counts = "all reads", file = "qiime2_full.zip"))
  expect_true("qiime2_counts.tsv" %in% zip::zip_list(mcp_file(mcp, data$download_url))$filename)

  data <- mcp$call("export", list(project = "hmp50", what = "mothur", rarefied = TRUE))$structuredContent
  expect_identical(data[c("counts", "file")], list(counts = "rarefied", file = "mothur_rare.zip"))
  counts <- utils::read.delim(file.path(local_unzip(mcp_file(mcp, data$download_url)), "mothur_counts.tsv"))
  expect_true(all(colSums(counts[, -(1:2)]) == 1183))

  skip_if_not_installed("phyloseq")

  data <- mcp$call("export", list(project = "hmp50", what = "phyloseq"))$structuredContent
  expect_identical(data$file, "phyloseq_full.rds")
  expect_s4_class(readRDS(mcp_file(mcp, data$download_url)), "phyloseq")
})
