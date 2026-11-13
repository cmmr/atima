#______________________________________________________________________________
# Work done in worker processes.
#
# Everything in this file runs in a worker (see `R/jobs.R`), never in the
# main process. These functions take a context, file paths and arguments the
# router has already validated; they read and write files, call rbiom, and
# return small results. They never see the database: the main process turns
# database ids into paths before a job starts and records new files after it
# ends.
#
# The context (`ctx`, from `worker_ctx()`) is
# `list(files_dir, cache_dir, cache_size, cpus)`.
#
# An error raised with `stop_user()` here reaches the browser as a 400, as it
# would from a handler.
#______________________________________________________________________________


#______________________________________________________________________________
#' Run one job. This is the function a worker process is asked to call.
#'
#' @param fn      The name of a function in this package.
#' @param args    Its arguments.
#' @param marker  A file to hold this process's id and temporary directory
#'                for as long as the job runs. It lets the main process see
#'                when an interrupted job has really stopped, and which
#'                process to end, and what to tidy up, if it has not.
#' @return `list(value = <result>, tempdir)`, or
#'         `list(error = list(status, message, detail, code), tempdir)` for an
#'         error meant for the user. Any other error is left to propagate.
#' @noRd
worker_run <- function (fn, args, marker = NULL) {

  if (!is.null(marker)) {
    writeLines(c(Sys.getpid(), worker_litter()), marker)
    on.exit(unlink(marker), add = TRUE)
  }

  outcome <- tryCatch(
    expr = list(value = do.call(get(fn, envir = asNamespace("atima"), mode = "function"), args)),
    atima_http_error = function (e) list(error = list(
      status  = e[['status']],
      message = conditionMessage(e),
      detail  = e[['detail']],
      code    = e[['code']] )))

  c(outcome, list(tempdir = worker_litter()))
}


#______________________________________________________________________________
#' What this process leaves on disk if it is ended instead of quitting: its
#' temporary directory and, on Windows, the small file `Rscript<pid in
#' hex><random>` that Rscript writes next to it when it starts.
#' @noRd
worker_litter <- function () {
  script <- list.files(
    path       = dirname(tempdir()),
    pattern    = sprintf("^Rscript%x[0-9a-f]*$", Sys.getpid()),
    full.names = TRUE )
  c(tempdir(), script[!dir.exists(script)])
}


#______________________________________________________________________________
#' Settings every job needs before it calls rbiom.
#'
#' Points rbiom's own cache at its half of the cache directory, and caps the
#' number of cores that rbiom (through ecodive and parallelly) will use for
#' functions that do not take a `cpus` argument.
#' @noRd
worker_init <- function (ctx) {
  cpus <- as.integer(ctx[['cpus']])
  options(
    rbiom.cache_dir  = file.path(ctx[['cache_dir']], "rbiom"),
    rbiom.cache_size = ctx[['cache_size']] / 2,
    parallelly.availableCores.custom = function () cpus )
  invisible(NULL)
}


#' atima's half of the cache directory.
#' @noRd
worker_cache <- function (ctx) {
  cache_at(file.path(ctx[['cache_dir']], "atima"), ctx[['cache_size']] / 2)
}


#' Make a check of an argument that the main process had to leave to the
#' worker. A failure is reported as the router would have reported it.
#' @param key   The argument's name.
#' @param code  A call to one of the `check_*()` functions in `R/schema.R`.
#' @noRd
worker_check <- function (key, code) {
  tryCatch(code, error = function (e) stop_arg(key, e))
}


#' Call an rbiom function with `cpus` pinned, if it takes that argument.
#' @noRd
with_cpus <- function (ctx, fn, args) {
  if ("cpus" %in% names(formals(fn)))
    args[['cpus']] <- as.integer(ctx[['cpus']])
  do.call(fn, args)
}


#______________________________________________________________________________
#' Read a stored BIOM file, keeping the parsed object in the cache.
#' @noRd
read_biom <- function (ctx, file) {
  key <- paste0("biom_", sub("\\.biom$", "", basename(file)))
  with_cache(worker_cache(ctx), key, as_rbiom(biom = file))
}


#______________________________________________________________________________
#' Write an rbiom object into the file store.
#' @return `list(file, hash)`, as from `store_file()`.
#' @noRd
store_biom <- function (ctx, biom) {

  tfile <- tempfile(fileext = ".json.bz2")
  on.exit(unlink(tfile), add = TRUE)

  write_biom(biom, file = tfile, format = "json")
  entry <- store_file(ctx[['files_dir']], tfile)

  # It is likely to be read again soon.
  cache_put(worker_cache(ctx), paste0("biom_", entry[['hash']]), biom)

  entry
}


#______________________________________________________________________________
#' Summary information for the `projects` table.
#' @return list(title, description, n_samples, ...)
#' @noRd
biom_to_details <- function (biom) {

  list(
    title         = biom$id,
    description   = pandoc_convert(text = biom$comment, to = 'html', args = '--wrap=none'),
    n_samples     = biom$n_samples,
    n_taxa        = biom$n_otus,
    has_tree      = !is.null(biom$tree),
    median_depth  = as.integer(median(sample_sums(biom))),
    meta_colnames = biom$fields )
}


#______________________________________________________________________________
#' What the browser, and the checks in `R/schema.R`, need to know about a
#' project's data. This is the BIOM-derived part of the front end's `BIOM`
#' variable; `session_biom()` adds the rest in the main process.
#'
#' The lists a control offers that do not depend on the data (metrics,
#' ordination and clustering methods, palettes) are in the schema, not here.
#' The names and values in a summary come from the user's file: they are
#' sent as JSON text and must be treated as text by whatever shows them.
#'
#' @return
#' \describe{
#'   \item{`tree`}{Does the project have a phylogenetic tree?}
#'   \item{`depth`, `depth_options`}{The current rarefaction depth, and the
#'     depths that would each drop a different set of samples.}
#'   \item{`fields`}{The metadata fields in column order, each
#'     `list(name, class = "categorical", levels)` or
#'     `list(name, class = "numeric", min, max)`. The classes are rbiom's
#'     (`rbiom::fn_check_data()`).}
#'   \item{`ranks`}{The taxonomic ranks.}
#'   \item{`taxa`}{For each rank, its taxa, most abundant first.}
#' }
#' @noRd
biom_summary <- function (full_biom, rare_biom) {

  D <- list()

  D[['tree']] <- unbox(!is.null(rare_biom$tree))

  # Current and possible rarefaction depths.
  D[['depth']]         <- unbox(rare_biom$depth)
  D[['depth_options']] <- sort(unique(sample_sums(full_biom)))

  # Metadata fields, with their values or range.
  metadata <- rare_biom$metadata
  classes  <- fn_check_data(rare_biom)[['fields']]

  D[['fields']] <- lapply(colnames(metadata), function (name) {

    values <- metadata[[name]]
    kind   <- classes[[name]][['class']]

    if (identical(kind, "numeric")) {
      values <- values[is.finite(values)]
      return (list(
        name  = unbox(name),
        class = unbox(kind),
        min   = unbox(if (length(values) > 0) min(values) else NA),
        max   = unbox(if (length(values) > 0) max(values) else NA) ))
    }

    list(
      name   = unbox(name),
      class  = unbox(kind),
      levels = if (is.factor(values)) levels(values) else sort(unique(as.character(values))) )
  })

  # taxa = list(Phylum = c(...), .otu = c(...), ...)
  D[['ranks']] <- rare_biom$ranks
  D[['taxa']]  <- list()
  for (rank in rare_biom$ranks)
    D[['taxa']][[rank]] <- names(taxa_means(rare_biom, rank))

  return (D)
}


#' The cached summary for a pair of stored files. The number in the key is
#' the version of the summary's layout; change it when `biom_summary()`
#' returns something different.
#' @noRd
cached_summary <- function (ctx, full, rare, full_biom = NULL, rare_biom = NULL) {
  key <- sprintf("data2_%s_%s", sub("\\.biom$", "", basename(full)), sub("\\.biom$", "", basename(rare)))
  with_cache(worker_cache(ctx), key, biom_summary(
    full_biom = full_biom %||% read_biom(ctx, full),
    rare_biom = rare_biom %||% read_biom(ctx, rare) ))
}


#' Store a full and a rarefied object and summarise them: the common ending
#' of every job that changes a project's data.
#' @return list(full, rare, data)
#' @noRd
store_pair <- function (ctx, full_biom, rare_biom) {
  full <- store_biom(ctx, full_biom)
  rare <- store_biom(ctx, rare_biom)
  list(
    full = full,
    rare = rare,
    data = cached_summary(ctx, full[['file']], rare[['file']], full_biom, rare_biom) )
}


#______________________________________________________________________________
# Jobs. Each `work_*()` function is one kind of job.
#______________________________________________________________________________


#' The summary of a project's data.
#' @return list(data)
#' @noRd
work_summary <- function (ctx, full, rare) {
  worker_init(ctx)
  list(data = cached_summary(ctx, full, rare))
}


#' The summary plus the values for the `projects` table, for saving.
#' @return list(data, details)
#' @noRd
work_details <- function (ctx, full, rare) {
  worker_init(ctx)
  list(
    data    = cached_summary(ctx, full, rare),
    details = biom_to_details(read_biom(ctx, full)) )
}


#______________________________________________________________________________
#' Turn an uploaded file into a project's three stored files.
#'
#' @param infile   The uploaded file.
#' @param title    A title to use instead of the one inside the file.
#' @param inflate  What to do with counts that are not whole numbers, such
#'                 as relative abundances. rbiom cannot rarefy those. `TRUE`
#'                 scales each sample up to whole numbers
#'                 (`rbiom::biom_inflate()`); `FALSE` refuses the file with
#'                 the error code `confirm_inflate`, so that the browser can
#'                 ask the user and send the file again.
#' @return list(orig, full, rare, data, details)
#' @noRd
work_import <- function (ctx, infile, title = NULL, inflate = FALSE) {

  worker_init(ctx)

  full_biom <- with_user_errors(
    message = "That file could not be read as a BIOM file.",
    detail  = FALSE,
    code    = as_rbiom(infile) )

  import_biom(ctx, full_biom, infile, title, inflate)
}


#______________________________________________________________________________
#' Turn a dataset that has just been read into the stored files of a new
#' project. `work_import()` does this for an upload; the legacy import does
#' it for a project rebuilt from an older atima's database.
#'
#' @param full_biom  The dataset, an rbiom object.
#' @param orig       The file it came from, kept as the project's original.
#' @param depth      The rarefaction depth to start with. `NULL`, or a depth
#'                   the data cannot be rarefied to, means rbiom's default.
#' @return As `work_import()`.
#' @noRd
import_biom <- function (ctx, full_biom, orig, title = NULL, inflate = FALSE, depth = NULL) {

  full_biom$sequences <- NULL
  if (!is.null(title)) full_biom$id <- title

  counts <- full_biom$counts@x

  if (any(counts %% 1 != 0)) {

    if (!isTRUE(inflate))
      stop_http(400L, code = "confirm_inflate", paste(
        "The counts in this file are not whole numbers (they look like relative abundances).",
        "atima can scale each sample up to whole numbers, using an estimate of its original",
        "number of reads. The estimate can be wrong: rare taxa may be lost or over-counted,",
        "so richness and other metrics that depend on rare taxa, rarefaction depths and",
        "count-based tests become unreliable. Upload the original counts if you have them." ))

    full_biom <- with_user_errors(
      message = "The counts in this file could not be scaled to whole numbers.",
      code    = biom_inflate(full_biom) )
  }

  rare_biom <- NULL

  if (!is.null(depth))
    rare_biom <- tryCatch(
      expr  = rarefy(full_biom, depth = depth, cpus = ctx[['cpus']]),
      error = function (e) NULL )

  if (is.null(rare_biom) || rare_biom$n_samples == 0)
    rare_biom <- rarefy(full_biom, cpus = ctx[['cpus']])

  c(
    list(orig = store_file(ctx[['files_dir']], orig)),
    store_pair(ctx, full_biom, rare_biom),
    list(details = biom_to_details(full_biom)) )
}


#' Import one of rbiom's example datasets (first-run seeding).
#' @noRd
work_seed <- function (ctx, dataset) {

  stopifnot(is_one_of(dataset, c("hmp50", "gems")))

  infile <- tempfile(fileext = ".json")
  on.exit(unlink(infile), add = TRUE)
  write_biom(biom = base::getExportedValue('rbiom', dataset), file = infile)

  work_import(ctx, infile)
}


#______________________________________________________________________________
#' Replace a project's metadata, taxonomy or tree with an uploaded file.
#' @return list(full, rare, data)
#' @noRd
work_component <- function (ctx, full, rare, component, infile) {

  worker_init(ctx)

  full_biom <- read_biom(ctx, full)
  depth     <- read_biom(ctx, rare)$depth

  with_user_errors(
    message = paste0("That file could not be read as ", component, "."),
    detail  = FALSE,
    code    = full_biom[[component]] <- infile )

  # Re-rarefy to the previous depth.
  rare_biom <- rarefy(full_biom, depth = depth, cpus = ctx[['cpus']])

  store_pair(ctx, full_biom, rare_biom)
}


#______________________________________________________________________________
#' Switch a metadata column between numeric and categorical.
#' @return list(full, rare, data)
#' @noRd
work_change_class <- function (ctx, full, rare, col_num) {

  worker_init(ctx)

  full_biom <- read_biom(ctx, full)
  depth     <- read_biom(ctx, rare)$depth
  md        <- full_biom$metadata

  if (col_num > ncol(md))
    stop_user("There is no metadata column ", col_num, ".")

  if (is.numeric(md[[col_num]])) {
    md[[col_num]] <- as.character(md[[col_num]])
  } else {
    md[[col_num]] <- as.numeric(as.character(md[[col_num]]))
  }

  full_biom$metadata <- md
  rare_biom <- rarefy(biom = full_biom, depth = depth, cpus = ctx[['cpus']])

  store_pair(ctx, full_biom, rare_biom)
}


#______________________________________________________________________________
#' Rarefy a project to a new depth, unless it is already at that depth.
#'
#' @return `list(changed = FALSE)`, or `list(changed = TRUE, rare, data)`.
#' @noRd
work_rarefy <- function (ctx, full, rare, depth) {

  worker_init(ctx)

  rarefied <- rarefy_to(ctx, full, rare, depth)
  if (is.null(rarefied)) return (list(changed = FALSE))

  list(
    changed = TRUE,
    rare    = rarefied[['rare']],
    data    = cached_summary(ctx, full, rarefied[['rare']][['file']], rare_biom = rarefied[['rare_biom']]) )
}


#' @return `NULL` if `rare` is already at `depth`, else
#'         `list(rare = <stored file>, rare_biom)`.
#' @noRd
rarefy_to <- function (ctx, full, rare, depth) {

  if (identical(as.integer(read_biom(ctx, rare)$depth), as.integer(depth)))
    return (NULL)

  rare_biom <- rarefy(read_biom(ctx, full), depth = as.integer(depth), cpus = ctx[['cpus']])

  list(rare = store_biom(ctx, rare_biom), rare_biom = rare_biom)
}


#______________________________________________________________________________
#' Write part of a project to a file the browser can download.
#'
#' @param src    The stored BIOM file to export from.
#' @param dest   The file to write.
#' @param what,format,method,rank  See `api_export()`.
#' @param title,description  Written into an exported BIOM file.
#' @param rare   For `xlsx`: the project's rarefied BIOM file, whose depth
#'               the workbook's rarefied sheets use.
#' @return `NULL`
#' @noRd
work_export <- function (ctx, src, dest, what, format, method, rank, title, description, rare = NULL) {

  worker_init(ctx)

  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

  if (what == "original") {
    atomic_write(dest, function (tmp) file.copy(src, tmp))
    return (NULL)
  }

  biom <- read_biom(ctx, src)

  if (what == "tree" && is.null(biom$tree))
    stop_user("This project has no phylogenetic tree.")

  # `method` and `rank` were checked against rbiom's lists and, when the
  # main process knew the project, against the project. What is left for
  # rbiom to refuse is reported in its own words.
  with_user_errors("The export could not be made.", atomic_write(dest, function (tmp) switch(
    EXPR     = what,
    metadata = write.csv(biom$metadata, tmp, row.names = FALSE),
    taxonomy = write.csv(biom$taxonomy, tmp, row.names = FALSE),
    tree     = write_tree(biom$tree, tmp),
    biom     = write_biom(annotate_biom(biom, title, description), tmp, format = format),
    alpha    = write.csv(with_cpus(ctx, adiv_matrix, list(biom)), tmp),
    beta     = write.csv(as.matrix(with_cpus(ctx, bdiv_distmat, list(biom, method))), tmp),
    taxa     = write.csv(taxa_matrix(biom, rank), tmp),
    xlsx     = export_xlsx(annotate_biom(biom, title, description), tmp, read_biom(ctx, rare)$depth) )))

  NULL
}


#' Write a project as an Excel workbook: counts, rarefied counts, metadata,
#' alpha diversity, taxonomy, and abundances at each rank.
#' @param file   The file to write. It need not end in `.xlsx`.
#' @param depth  The rarefaction depth for the rarefied sheets.
#' @noRd
export_xlsx <- function (biom, file, depth) {

  # openxlsx picks the format from the file's extension.
  xlsx <- tempfile(fileext = ".xlsx")
  on.exit(unlink(xlsx), add = TRUE)

  write_xlsx(biom, xlsx, depth = depth)
  file.copy(xlsx, file, overwrite = TRUE)
}


#______________________________________________________________________________
#' Group a project's samples into clusters and add the result to its
#' metadata as a categorical field.
#'
#' @param cluster_fn    `"taxa_clusters"` or `"bdiv_clusters"`.
#' @param cluster_args  Its arguments.
#' @param name          The new field's name.
#' @param checked       Were `cluster_args` checked against the project in
#'                      the main process?
#' @return list(full, rare, data)
#' @noRd
work_add_clusters <- function (ctx, full, rare, cluster_fn, cluster_args, name, checked = TRUE) {

  worker_init(ctx)

  if (!isTRUE(checked))
    cluster_args <- worker_check("cluster_args", check_fn_args(cluster_fn, cluster_args, cached_summary(ctx, full, rare)))

  full_biom <- read_biom(ctx, full)
  rare_biom <- read_biom(ctx, rare)

  if (tolower(name) %in% tolower(full_biom$fields))
    stop_user("This project already has a metadata field called '", name, "'.")

  # Clusters are found among the rarefied samples, like everything else
  # that compares samples. A sample that rarefying dropped is in no cluster.
  clusters <- with_user_errors("The samples could not be clustered.", with_cpus(
    ctx  = ctx,
    fn   = base::getExportedValue("rbiom", cluster_fn),
    args = c(list(biom = rare_biom), cluster_args) ))

  # Named, not numbered, so that the field stays categorical when the
  # project is saved and read again.
  labels <- paste("Cluster", as.character(clusters))
  names(labels) <- names(clusters)

  md <- full_biom$metadata
  md[[name]] <- unname(labels[as.character(md[['.sample']])])
  full_biom$metadata <- md

  store_pair(ctx, full_biom, rarefy(full_biom, depth = rare_biom$depth, cpus = ctx[['cpus']]))
}


#' Put a project's current title and description into its BIOM object.
#' @noRd
annotate_biom <- function (biom, title, description) {
  biom$id      <- title
  biom$comment <- paste0(collapse = '\n', pandoc_convert(
    text = description, from = 'html', to = 'markdown' ))
  biom
}


#______________________________________________________________________________
#' Write a project's BIOM file in the format a download asked for.
#'
#' @param src   The stored BIOM file.
#' @param dir   A directory for the result.
#' @param file  `<rare|full>.<tab|json|hdf5>[.gz|.bz2]`.
#' @return list(path)
#' @noRd
work_download <- function (ctx, src, dir, file, title, description) {

  worker_init(ctx)

  format <- strsplit(file, ".", fixed = TRUE)[[1]][[2]]
  biom   <- annotate_biom(read_biom(ctx, src), title, description)

  # The extension tells rbiom which compression to use.
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- tempfile(pattern = "download_", tmpdir = dir, fileext = sub("^[a-z]+", "", file))
  write_biom(biom, path, format)

  list(path = path)
}


#______________________________________________________________________________
#' One page of a project's metadata or taxonomy table.
#' @return list(draw, recordsTotal, recordsFiltered, data)
#' @noRd
work_table_page <- function (ctx, src, what, draw, start, length, search, order) {
  worker_init(ctx)
  dt_page(read_biom(ctx, src)[[what]], draw, start, length, search, order)
}


#' The header rows of a project's metadata or taxonomy table.
#' @return list(html)
#' @noRd
work_table_head <- function (ctx, src, what) {
  worker_init(ctx)
  df <- read_biom(ctx, src)[[what]]
  list(html = unbox(if (what == "metadata") metadata_thead(df) else taxonomy_thead(df)))
}


