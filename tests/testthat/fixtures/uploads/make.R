# Writes the QIIME 2 artifacts in this directory. They are zip archives, so
# they are kept in git instead of being made by the tests, which would then
# need a zip program. Run from this directory:
#
#   Rscript make.R
#
# The dataset is the one `upload_biom()` in helper-import.R makes: the
# first eight samples of rbiom's hmp50 and the thirty OTUs most abundant
# in them. The feature table holds only counts, as QIIME 2's does.

library(rbiom)

biom <- hmp50[1:8]
biom <- biom$clone()
keep <- names(sort(rowSums(as.matrix(biom$counts)), decreasing = TRUE))[1:30]
biom$counts <- biom$counts[keep, ]

artifact <- function (file, type, payload, write) {

  uuid <- "0a1b2c3d-1111-4222-8333-444455556666"
  root <- tempfile("qza")
  dir.create(file.path(root, uuid, "data"), recursive = TRUE)

  writeLines(c(paste0("uuid: ", uuid), paste0("type: ", type), "format: TestDirectoryFormat"), file.path(root, uuid, "metadata.yaml"))
  write(file.path(root, uuid, "data", payload))

  out <- file.path(getwd(), file)
  unlink(out)
  old <- setwd(root)
  on.exit(setwd(old))
  utils::zip(out, uuid, flags = "-r9Xq")
}

artifact("table.qza", "FeatureTable[Frequency]", "feature-table.biom", function (path) {
  write_biom(as_rbiom(biom$counts), path, format = "hdf5")
})

artifact("taxonomy.qza", "FeatureData[Taxonomy]", "taxonomy.tsv", function (path) {
  ranks <- as.data.frame(biom$taxonomy)
  table <- data.frame(
    "Feature ID" = ranks[[".otu"]],
    "Taxon"      = apply(ranks[, -1], 1, paste, collapse = "; "),
    "Confidence" = 0.99,
    check.names  = FALSE )
  utils::write.table(table, path, sep = "\t", quote = FALSE, row.names = FALSE)
})

artifact("tree.qza", "Phylogeny[Rooted]", "tree.nwk", function (path) {
  write_tree(biom$tree, path)
})

artifact("visualization.qzv", "Visualization", "index.html", function (path) {
  writeLines("<!DOCTYPE html><title>A visualization</title>", path)
})
