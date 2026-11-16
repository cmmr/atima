# Uploads (R/import.R, `work_import()`, `work_component()`): the kinds of
# file that are accepted, and what the user is told about a file that is
# not, or that lost something on the way in.


# Messages -------------------------------------------------------------------

test_that("an uploaded file's name is made fit for a message", {

  expect_identical(upload_name("gut study.biom"), "gut study.biom")
  expect_identical(upload_name("C:\\Users\\me\\Desktop\\table.qza"), "table.qza")
  expect_identical(upload_name("/home/me/data/table.qza"), "table.qza")
  expect_identical(upload_name("a\tb\nc.tsv"), "a b c.tsv")
  expect_identical(nchar(upload_name(strrep("a", 300))), 100L)

  expect_null(upload_name(""))
  expect_null(upload_name("dir/"))
  expect_null(upload_name(NULL))
  expect_null(upload_name(NA_character_))
})


test_that("rbiom's message is unwrapped, and the file is called by its own name", {

  dir    <- withr::local_tempdir(pattern = "atima_import_")
  infile <- file.path(dir, "upload_1a2b3c4d5e")
  writeLines("x", infile)
  full   <- normalizePath(infile, winslash = "/")

  cross <- intToUtf8(0x2716)
  info  <- intToUtf8(0x2139)
  dot   <- intToUtf8(0x2022)

  # Bullets, a wrapped line, colour codes.
  text <- paste0(
    cross, " Sample column \"A\" of '", full, "' looks like it has decimal\n",
    "  commas, e.g. \"0,5\".\n",
    info, " Re-export the file with \033[34m\".\"\033[39m as the decimal mark" )

  expect_identical(
    import_text(text, infile, "counts.tsv"),
    paste(sep = "\n",
      "Sample column \"A\" of 'counts.tsv' looks like it has decimal commas, e.g. \"0,5\".",
      "Re-export the file with \".\" as the decimal mark." ))

  # A path too long for the line is put on a line of its own, without a
  # bullet. With backslashes, without quotes, and cut to its last part.
  expect_identical(import_text(paste0("No data found in\n'", full, "'."), infile, "empty.txt"), "No data found in 'empty.txt'.")
  expect_identical(import_text(paste0("Can't read ", gsub("/", "\\", full, fixed = TRUE), ": bad"), infile, "a.txt"), "Can't read 'a.txt': bad.")
  expect_identical(import_text("'upload_1a2b3c4d5e' is a binary file", infile, "a.bin"), "'a.bin' is a binary file.")
  expect_identical(import_text("'upload_1a2b3c4d5e' is a binary file", infile, NULL), "the uploaded file is a binary file.")

  # Lists stay one to a line; R's object is the project; advice about an
  # argument of rbiom's is left out.
  text <- paste(sep = "\n",
    paste(info, "Dropping 2 samples from biom object since they are not in the new metadata."),
    paste(dot, "Expected: \"A\" and \"B\""),
    paste(info, "Unquoted underscores are read as spaces unless `underscores = TRUE`.") )
  expect_identical(
    import_text(text, infile),
    "Dropping 2 samples from the project since they are not in the new metadata.\nExpected: \"A\" and \"B\"." )

  # A message that names any other place on the server is not shown.
  expect_null(import_text(paste0("cannot open file '", dir, "/other'"), infile, "a.txt"))
  expect_null(import_text(paste0("cannot open ", file.path(tempdir(), "qza123", "feature-table.biom")), infile, "a.txt"))
  expect_null(import_text(paste0("bad file in ", toupper(gsub("/", "\\", dirname(full), fixed = TRUE))), infile, "a.txt"))
  expect_null(import_text("in /srv/atima/files/ab/cdef.biom", infile, "a.txt", dirs = "/srv/atima/files"))
  expect_null(import_text("", infile))

  # Never longer than a screen can show.
  expect_lte(nchar(import_text(strrep("word ", 2000), infile)), 1503L)
})


test_that("import_try keeps the error and the warnings, worded while its options hold", {

  out <- import_try({ warning("first"); warning("second"); 42 })
  expect_identical(out, list(value = 42, warnings = c("first", "second")))

  out <- import_try({ warning("first"); stop("no good") })
  expect_identical(conditionMessage(out$error), "no good")
  expect_identical(out$warnings, "first")

  # rlang words a cli message when it is asked for. Asked inside, a long
  # line is not broken.
  long <- paste(rep("word", 60), collapse = " ")
  out  <- import_try(rlang::abort(c(x = long, i = "more")))
  expect_identical(conditionMessage(out$error), paste0(intToUtf8(0x2716), " ", long, "\n", intToUtf8(0x2139), " more"))

  # An error that is already the user's passes through as it is.
  out <- import_try(stop_user("as it is"))
  expect_s3_class(out$error, "atima_http_error")
  expect_error(import_stop("x", out$error, identity), "^as it is$", class = "atima_http_error")
})


test_that("a file that needs a package the server lacks says so, not how to install it", {

  cli_text <- paste0(
    intToUtf8(0x2716), " The h5lite R package is required to read HDF5 formatted BIOM files.\n",
    intToUtf8(0x2139), " To install h5lite, run:\n",
    intToUtf8(0x2192), " pak::pkg_install('h5lite')" )

  e <- refusal(import_stop("This file could not be imported.", simpleError(cli_text), function (text) text))
  expect_identical(
    conditionMessage(e),
    "This file could not be imported.\nThis server cannot read that kind of file: the h5lite package is not installed." )
  expect_match(e$detail, "pkg_install")
})


# New projects ---------------------------------------------------------------

test_that("a BIOM file is imported, as JSON and as HDF5", {

  im   <- local_import()
  biom <- upload_biom()

  json <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, json, format = "json")

  out <- im$import(json, "gut.biom", title = "Gut")
  expect_named(out, c("orig", "full", "rare", "data", "details", "notes"))
  expect_identical(out$details[c("title", "n_samples", "n_taxa", "has_tree")], list(title = "Gut", n_samples = 8L, n_taxa = 30L, has_tree = TRUE))
  expect_identical(out$notes, character(0))

  skip_if_not_installed("h5lite")

  hdf5 <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, hdf5, format = "hdf5")

  out <- im$import(hdf5, "gut.h5")
  expect_identical(out$details[c("n_samples", "n_taxa", "has_tree")], list(n_samples = 8L, n_taxa = 30L, has_tree = TRUE))
  expect_identical(out$notes, character(0))
})


test_that("a QIIME 2 feature table is imported, and its taxonomy and tree added from artifacts", {

  skip_if_not_installed("h5lite")

  im   <- local_import()
  biom <- upload_biom()

  out <- im$import(upload_fixture("table.qza"), title = "From QIIME 2")
  expect_identical(out$details[c("title", "n_samples", "n_taxa", "has_tree")], list(title = "From QIIME 2", n_samples = 8L, n_taxa = 30L, has_tree = FALSE))
  expect_identical(out$data$ranks, ".otu")
  expect_identical(out$notes, character(0))

  stored <- rbiom::as_rbiom(im$stored(out$full))
  expect_identical(as.matrix(stored$counts)[biom$otus, biom$samples], as.matrix(biom$counts))

  # The taxonomy: lineages are split into ranks, the confidence is dropped.
  with_ranks <- im$replace(out, "taxonomy", upload_fixture("taxonomy.qza"))
  expect_identical(with_ranks$data$ranks, c(".otu", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus"))
  expect_identical(with_ranks$notes, character(0))

  stored <- rbiom::as_rbiom(im$stored(with_ranks$full))
  expect_identical(
    as.character(stored$taxonomy$Genus[match(biom$otus, stored$taxonomy$.otu)]),
    as.character(biom$taxonomy$Genus) )

  # The tree.
  with_tree <- im$replace(with_ranks, "tree", upload_fixture("tree.qza"))
  expect_true(with_tree$data$tree)
  expect_identical(with_tree$notes, character(0))
  expect_setequal(rbiom::as_rbiom(im$stored(with_tree$full))$tree$tip.label, biom$otus)
})


test_that("a mothur shared file and a table of counts are imported", {

  im     <- local_import()
  counts <- as.matrix(upload_biom()$counts)

  shared <- data.frame(label = "0.03", Group = colnames(counts), numOtus = nrow(counts), t(counts), check.names = FALSE)
  file   <- withr::local_tempfile(fileext = ".shared")
  utils::write.table(shared, file, sep = "\t", quote = FALSE, row.names = FALSE)

  out <- im$import(file, "stability.opti_mcc.shared")
  expect_identical(out$details[c("n_samples", "n_taxa", "has_tree")], list(n_samples = 8L, n_taxa = 30L, has_tree = FALSE))
  expect_identical(out$notes, character(0))
  stored <- rbiom::as_rbiom(im$stored(out$full))
  expect_identical(as.matrix(stored$counts)[rownames(counts), colnames(counts)], counts)

  # Two labels in one file: rbiom says which, and what to do.
  two <- rbind(shared, transform(shared, label = "0.05"))
  utils::write.table(two, file, sep = "\t", quote = FALSE, row.names = FALSE)
  e <- refusal(im$import(file, "two.shared"))
  expect_match(conditionMessage(e), "'two.shared' has 2 labels: \"0.03\" and \"0.05\"")
  expect_match(conditionMessage(e), "Remove the rows for all but one label")

  # A table with a taxonomy column, as CSV. A column of text is left out,
  # and a note says so.
  table <- data.frame("#OTU ID" = rownames(counts), counts, Notes = "seen before", taxonomy = "Bacteria; Firmicutes", check.names = FALSE)
  csv   <- withr::local_tempfile(fileext = ".csv")
  utils::write.csv(table, csv, row.names = FALSE)

  out <- im$import(csv, "table.csv")
  expect_identical(out$details[c("n_samples", "n_taxa")], list(n_samples = 8L, n_taxa = 30L))
  expect_identical(out$data$ranks, c(".otu", "Level.1", "Level.2"))
  expect_identical(out$notes, "Ignoring non-numeric column in 'table.csv': \"Notes\".")
})


test_that("the templates beside the upload button are files atima reads", {

  im <- local_import()

  counts   <- system.file("www", "templates", "counts-template.tsv", package = "atima")
  metadata <- system.file("www", "templates", "metadata-template.csv", package = "atima")
  expect_true(nzchar(counts) && nzchar(metadata))

  out <- im$import(counts, "counts-template.tsv")
  expect_identical(out$details[c("n_samples", "n_taxa")], list(n_samples = 6L, n_taxa = 6L))
  expect_identical(out$data$ranks, c(".otu", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus"))
  expect_identical(out$notes, character(0))

  out <- im$replace(out, "metadata", metadata, "metadata-template.csv")
  expect_identical(out$notes, character(0))
  expect_identical(
    lapply(out$data$fields, function (f) f[c("name", "class")]),
    list(
      list(name = unbox(".sample"), class = unbox("categorical")),
      list(name = unbox("Group"),   class = unbox("categorical")),
      list(name = unbox("Age"),     class = unbox("numeric")),
      list(name = unbox("Sex"),     class = unbox("categorical")) ))
  expect_identical(rbiom::as_rbiom(im$stored(out$full))$n_samples, 6L)
})


test_that("a file that cannot be imported is refused with the reason, and no server path", {

  im     <- local_import()
  counts <- as.matrix(upload_biom()$counts)
  table  <- data.frame("#OTU ID" = rownames(counts), counts, check.names = FALSE)

  refused <- function (file, name, ...) {
    e <- refusal(im$import(file, name))
    expect_match(conditionMessage(e), "^This file could not be imported\\.\n")
    for (pattern in c(...)) expect_match(conditionMessage(e), pattern, fixed = TRUE)
    expect_no_server_path(conditionMessage(e), im)
    invisible(e)
  }

  # Decimal commas. The log has rbiom's own words, path and all.
  commas <- table
  commas[[2]] <- paste0(commas[[2]], ",5")
  file <- withr::local_tempfile()
  utils::write.table(commas, file, sep = "\t", quote = FALSE, row.names = FALSE)
  e <- refused(file, "counts.tsv",
    "Sample column \"HMP01\" of 'counts.tsv' looks like it has decimal commas, e.g.",
    "Re-export the file with \".\" as the decimal mark" )
  expect_match(e$detail, "upload_[0-9a-f]+")

  # A word among the counts.
  words <- table
  words[3, 2] <- "n/a"
  utils::write.table(words, file, sep = "\t", quote = FALSE, row.names = FALSE)
  refused(file, "counts.tsv", "Non-numeric value \"n/a\" for OTU", "in sample column \"HMP01\" of 'counts.tsv'")

  # Not a table at all, nothing at all, and bytes.
  refused(im$written("this is not a biom file"), "junk.biom", "No abundance counts in 'junk.biom'.")
  refused(im$written(""), "empty.txt", "No data found in 'empty.txt'.")
  writeBin(as.raw(rep(c(0, 200, 7, 255), 500)), file)
  refused(file, "photo.png", "'photo.png' is a binary file, not delimited text.")

  # JSON that is not BIOM.
  refused(im$written('{"a": 1}'), "settings.json", "BIOM file is missing")

  # An Excel workbook (the old format's first bytes are enough to tell).
  writeBin(c(as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)), raw(600)), file)
  refused(file, "counts.xls", "'counts.xls' is an Excel file, which can't be read as a counts table.", "Save the worksheet as tab-separated text")

  # QIIME 2 files of another kind.
  refused(upload_fixture("taxonomy.qza"), "taxonomy.qza", "'taxonomy.qza' is a QIIME 2 \"FeatureData[Taxonomy]\" artifact, not a feature table.")
  refused(upload_fixture("tree.qza"), "rooted-tree.qza", "'rooted-tree.qza' is a QIIME 2 \"Phylogeny[Rooted]\" artifact, not a feature table.")
  refused(upload_fixture("visualization.qzv"), "table.qzv", "'table.qzv' is a QIIME 2 visualization, not data.")

  # A file whose name was not sent.
  e <- refusal(work_import(im$ctx, im$upload(im$written("")), filename = NULL))
  expect_identical(conditionMessage(e), "This file could not be imported.\nNo data found in the uploaded file.")

  # Nothing was stored for any of them.
  expect_length(list.files(im$ctx$files_dir, recursive = TRUE), 0)
})


test_that("a message that would name a server file gives way to a list of what is accepted", {

  im <- local_import()

  # As rbiom would word a failure inside an artifact it had unpacked.
  local_mocked_bindings(as_rbiom = function (biom, ...) stop("Can't read JSON file '", file.path(tempdir(), "qza1f2e", "feature-table.biom"), "': bad"))

  e <- refusal(im$import(im$written("x"), "table.qza"))
  expect_identical(conditionMessage(e), paste0("This file could not be imported.\n", upload_kinds))
  expect_match(e$detail, "feature-table.biom", fixed = TRUE)
})


test_that("a file whose tree does not match its counts becomes a project without a tree", {

  im   <- local_import()
  biom <- upload_biom()

  with_tree <- function (newick) {
    file <- withr::local_tempfile(.local_envir = parent.frame())
    rbiom::write_biom(biom, file, format = "json")
    json <- jsonlite::read_json(file)
    json$phylogeny <- newick
    jsonlite::write_json(json, file, auto_unbox = TRUE, null = "null")
    file
  }

  out <- im$import(with_tree("((A:1,B:2):1,C:3);"), "gut.biom")
  expect_false(out$details$has_tree)
  expect_false(out$data$tree)
  expect_identical(out$details$n_taxa, 30L)
  expect_null(rbiom::as_rbiom(im$stored(out$full))$tree)

  expect_length(out$notes, 1)
  expect_match(out$notes, "^The phylogenetic tree in this file does not match its counts, so the project was made without a tree\\.")
  expect_match(out$notes, "OTUs missing from tree: 30 of 30")
  expect_match(out$notes, "Tree tips not in the counts table: 3 of 3, e.g. \"A\", \"B\", and \"C\"\\.")
  expect_match(out$notes, "not offered until a matching tree is added to the project\\.$")
  expect_no_server_path(out$notes, im)

  # A file that is wrong in another way is not read three times over.
  reads <- 0L
  local_mocked_bindings(as_rbiom = function (biom, ...) { reads <<- reads + 1L; stop("No abundance counts.") })
  refusal(im$import(im$written("x"), "x.txt"))
  expect_identical(reads, 1L)
})


test_that("underscores in a tree's names are kept when that is what makes it fit", {

  im   <- local_import()
  biom <- upload_biom()

  # OTU_1, OTU_2, ...: by Newick's rules an unquoted OTU_1 is "OTU 1".
  names  <- paste0("OTU_", seq_len(biom$n_otus))
  counts <- as.matrix(biom$counts)
  tree   <- biom$tree
  tree$tip.label <- names[match(tree$tip.label, rownames(counts))]
  rownames(counts) <- names

  newick <- gsub("'", "", rbiom::write_tree(tree), fixed = TRUE)
  expect_match(newick, "OTU_1:", fixed = TRUE)

  # Inside a BIOM file.
  file <- withr::local_tempfile()
  rbiom::write_biom(rbiom::as_rbiom(counts), file, format = "json")
  json <- jsonlite::read_json(file)
  json$phylogeny <- newick
  jsonlite::write_json(json, file, auto_unbox = TRUE, null = "null")

  out <- im$import(file, "underscores.biom")
  expect_true(out$details$has_tree)
  expect_identical(out$notes, character(0))
  expect_setequal(rbiom::as_rbiom(im$stored(out$full))$tree$tip.label, names)

  # As a tree file for a project that has none.
  file <- withr::local_tempfile()
  rbiom::write_biom(rbiom::as_rbiom(counts), file, format = "json")
  bare <- im$import(file, "bare.biom")
  expect_false(bare$details$has_tree)

  out <- im$replace(bare, "tree", im$written(newick), "tree.nwk")
  expect_true(out$data$tree)
  expect_identical(out$notes, character(0))
  expect_setequal(rbiom::as_rbiom(im$stored(out$full))$tree$tip.label, names)
})


# Replacing a part -----------------------------------------------------------

test_that("new metadata must name the project's samples; samples it leaves out are dropped with a note", {

  im   <- local_import()
  biom <- upload_biom()
  file <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, file, format = "json")
  project <- im$import(file, "gut.biom")

  md  <- as.data.frame(biom$metadata)
  csv <- withr::local_tempfile(fileext = ".csv")

  refused <- function (file, name, ...) {
    e <- refusal(im$replace(project, "metadata", file, name))
    expect_match(conditionMessage(e), "^That file could not be used as the project's metadata\\.\n")
    expect_match(conditionMessage(e), "\nThe metadata was not changed\\.$")
    for (pattern in c(...)) expect_match(conditionMessage(e), pattern, fixed = TRUE)
    expect_no_server_path(conditionMessage(e), im)
  }

  # Other samples altogether.
  other <- md
  other$.sample <- paste0("S", seq_len(nrow(md)))
  utils::write.csv(other, csv, row.names = FALSE)
  refused(csv, "samples.csv",
    "No matching sample names between counts and metadata in 'samples.csv'.",
    "Expected: \"HMP01\", \"HMP02\"",
    "Provided: \"S1\", \"S2\"" )

  # The same names in another case: rbiom points it out.
  lower <- md
  lower$.sample <- tolower(md$.sample)
  utils::write.csv(lower, csv, row.names = FALSE)
  refused(csv, "samples.csv", "Sample names differ only by case, whitespace, or punctuation: \"HMP01\" vs \"hmp01\".")

  # Files of another kind.
  refused(upload_fixture("table.qza"), "table.qza", "'table.qza' is a QIIME 2 \"FeatureTable[Frequency]\" artifact, not a table of taxonomy or metadata.")
  refused(im$written(""), "empty.csv", "No data found in 'empty.csv'.")

  # A refused file leaves the dataset as it was, also the copy a worker
  # keeps in memory.
  again <- work_summary(im$ctx, im$stored(project$full), im$stored(project$rare))
  expect_identical(again$data, project$data)
  expect_identical(read_biom(im$ctx, im$stored(project$full))$n_samples, 8L)

  # Five of the eight samples, with a column of decimal commas.
  part <- md[1:5, ]
  part$Dose <- c("1,5", "2,5", "0,5", "3", "4,25")
  utils::write.csv(part, csv, row.names = FALSE)

  out <- im$replace(project, "metadata", csv, "five.csv")
  expect_identical(rbiom::as_rbiom(im$stored(out$full))$n_samples, 5L)
  expect_identical(out$data$fields[[6]][c("name", "class")], list(name = unbox("Dose"), class = unbox("categorical")))

  expect_length(out$notes, 2)
  expect_match(out$notes[[1]], "^Looks like decimal commas in metadata in 'five.csv'; read as categorical: \"Dose\"\\.")
  expect_match(out$notes[[2]], "^Dropping 3 samples from the project since they are not in the new metadata in 'five.csv': \"HMP06\", \"HMP07\", and \"HMP08\"\\.$")
  expect_no_server_path(out$notes, im)
})


test_that("new taxonomy drops the OTUs it leaves out, and the depth follows if it must", {

  im   <- local_import()
  biom <- upload_biom()
  file <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, file, format = "json")
  project <- im$import(file, "gut.biom")

  # A table that is not about these OTUs.
  e <- refusal(im$replace(project, "taxonomy", system.file("www", "templates", "metadata-template.csv", package = "atima"), "metadata.csv"))
  expect_match(conditionMessage(e), "^That file could not be used as the project's taxonomy\\.\n")
  expect_match(conditionMessage(e), "No column matched the OTU names")
  expect_match(conditionMessage(e), "\nThe taxonomy was not changed\\.$")

  # Only the five rarest OTUs: no sample reaches the old depth any more.
  rare5 <- names(sort(rowSums(as.matrix(biom$counts))))[1:5]
  table <- as.data.frame(biom$taxonomy)
  table <- table[table$.otu %in% rare5, ]
  csv   <- withr::local_tempfile(fileext = ".csv")
  utils::write.csv(table, csv, row.names = FALSE)

  out <- im$replace(project, "taxonomy", csv, "five.csv")
  expect_identical(rbiom::as_rbiom(im$stored(out$full))$n_otus, 5L)
  expect_lt(out$data$depth, project$data$depth)

  expect_length(out$notes, 2)
  expect_match(out$notes[[1]], "^Dropping 25 OTUs from the project since they are not in the new taxonomy: ")
  expect_identical(out$notes[[2]], sprintf(
    "No sample has %i reads any more, so the project is now rarefied to %i.", project$data$depth, out$data$depth ))
})


test_that("a tree that does not cover the project's OTUs is refused, with what to do", {

  im   <- local_import()
  biom <- upload_biom()
  file <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, file, format = "json")
  project <- im$import(file, "gut.biom")

  refused <- function (file, name, ...) {
    e <- refusal(im$replace(project, "tree", file, name))
    expect_match(conditionMessage(e), "^That file could not be used as the project's tree\\.\n")
    expect_match(conditionMessage(e), "\nThe tree was not changed\\.$")
    for (pattern in c(...)) expect_match(conditionMessage(e), pattern, fixed = TRUE)
    expect_no_server_path(conditionMessage(e), im)
    invisible(e)
  }

  # The tree of other OTUs.
  other <- biom$tree
  other$tip.label <- paste0("T", seq_along(other$tip.label))
  refused(im$written(rbiom::write_tree(other)), "other.nwk",
    "OTUs missing from tree: 30 of 30, e.g.",
    "Tree tips not in the counts table: 30 of 30, e.g. \"T1\"",
    "Every OTU must be a tip in the tree.",
    "Use the tree that was built from this project's own OTUs, with the same names.",
    "Tips the project does not have are fine; they are left out." )

  # Not Newick.
  e <- refused(im$written(c("#NEXUS", "begin trees;", "end;")), "tree.nex", "'tree.nex' is a NEXUS tree; Newick format is required.")
  expect_no_match(conditionMessage(e), "Use the tree that was built")
  refused(im$written("not a tree"), "notes.txt", "'notes.txt' is not a Newick tree.")
  refused(upload_fixture("taxonomy.qza"), "taxonomy.qza", "'taxonomy.qza' is a QIIME 2 \"FeatureData[Taxonomy]\" artifact, not a phylogenetic tree.")

  # The project still has its tree.
  expect_true(work_summary(im$ctx, im$stored(project$full), im$stored(project$rare))$data$tree)

  # A tree with more tips than the project has OTUs is fine.
  whole <- im$replace(project, "tree", im$written(rbiom::write_tree(rbiom::hmp50$tree)), "hmp50.nwk")
  expect_true(whole$data$tree)
  expect_identical(whole$notes, character(0))
  expect_setequal(rbiom::as_rbiom(im$stored(whole$full))$tree$tip.label, biom$otus)
})


# Through the server ---------------------------------------------------------

test_that("the upload routes return the notes, and the reason a file was refused", {

  s    <- local_open_project()
  biom <- upload_biom()

  # The browser is told the largest upload.
  expect_identical(max_upload_mb(list()), 50L)
  expect_identical(max_upload_mb(list(max_upload_mb = 200)), 200L)
  resp <- handle_request(fake_request("POST", "/api/session/init", list(), session = s$session), s$app)
  expect_identical(response_json(resp)$CONF$max_upload_mb, 50L)

  # A new project from a file whose tree does not fit.
  file <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, file, format = "json")
  json <- jsonlite::read_json(file)
  json$phylogeny <- "((A:1,B:2):1,C:3);"
  jsonlite::write_json(json, file, auto_unbox = TRUE, null = "null")

  resp <- s$upload(file, "C:\\data\\gut study.biom")
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$BIOM$title, "gut study")
  expect_false(body$BIOM$tree)
  expect_length(body$notes, 1)
  expect_match(body$notes[[1]], "the project was made without a tree")

  # One note is still a list.
  expect_match(resp$body, '"notes":["The phylogenetic tree', fixed = TRUE)

  # A file that is refused: the reason, the file's own name, no path.
  table <- data.frame("#OTU ID" = biom$otus, as.matrix(biom$counts), check.names = FALSE)
  table[[2]] <- paste0(table[[2]], ",5")
  tsv <- withr::local_tempfile(fileext = ".tsv")
  utils::write.table(table, tsv, sep = "\t", quote = FALSE, row.names = FALSE)

  read_log <- local_log()
  resp <- s$upload(tsv, "counts.tsv")
  expect_identical(resp$status, 400L)
  message <- response_json(resp)$error$message
  expect_match(message, "^This file could not be imported\\.\nSample column \"HMP01\" of 'counts.tsv' looks like it has decimal commas")
  expect_no_server_path(resp$body)

  entry <- log_errors(read_log())[[1]]
  expect_identical(entry$level, "info")
  expect_match(entry$detail, "upload_[0-9a-f]+")

  # Replacing the metadata of the working copy with a file that lists
  # fewer samples.
  csv <- withr::local_tempfile(fileext = ".csv")
  utils::write.csv(as.data.frame(biom$metadata)[1:6, ], csv, row.names = FALSE)
  form <- multipart_body(list(component = "metadata", component_file = list(filename = "six.csv", value = read_file_raw(csv))))
  resp <- handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 200L)
  body <- response_json(resp)
  expect_identical(body$notes, list("Dropping 2 samples from the project since they are not in the new metadata in 'six.csv': \"HMP07\" and \"HMP08\"."))
  expect_false(body$BIOM$is_saved)

  # Nothing to note: an empty list, not a missing one.
  utils::write.csv(as.data.frame(biom$metadata)[1:6, ], csv, row.names = FALSE)
  form <- multipart_body(list(component = "metadata", component_file = list(filename = "six.csv", value = read_file_raw(csv))))
  resp <- handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(response_json(resp)$notes, list())

  # A tree that does not fit.
  form <- multipart_body(list(component = "tree", component_file = list(filename = "other.nwk", value = charToRaw("((A:1,B:2):1,C:3);"))))
  resp <- handle_request(fake_request("POST", "/api/project/upload_component", form$body, s$session, content_type = form$content_type), s$app)
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "OTUs missing from tree: 30 of 30")
  expect_match(response_json(resp)$error$message, "The tree was not changed\\.$")
  expect_no_server_path(resp$body)

  # No upload was left behind.
  expect_length(list.files(s$temp, pattern = "^upload_"), 0)
})
