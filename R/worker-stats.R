#______________________________________________________________________________
# Running a statistics function. Runs in a worker process; see `R/worker.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Run one of rbiom's functions that return a table (a statistics function,
#' or one whose table is the result itself) and save the table.
#'
#' The steps before the function is called are those of `work_plot()`:
#' finish checking the arguments if the main process could not, rarefy to
#' the depth asked for, keep the samples asked for.
#'
#' @param ctx          The worker context.
#' @param full,rare    The project's stored BIOM files.
#' @param out_dir      A directory for the table, as a CSV file.
#' @param stats_fn     The name of an exposed rbiom function of use `stats`
#'                     or `table`.
#' @param stats_args   Its arguments.
#' @param subset_args  The samples to keep; see `subset_biom()`.
#' @param depth        The rarefaction depth to use, or `NULL` for the depth
#'                     of `rare`.
#' @param max_rows     The most rows of the table to send back.
#' @param checked      Were `stats_args` and `subset_args` checked against
#'                     the project in the main process?
#' @param keys         What the caller calls `stats_args` and `subset_args`,
#'                     for the message when one of them fails that check.
#' @param keep_depth   Does the caller keep the project at `depth`, as the
#'                     browser does? Then, if the project had to be rarefied,
#'                     `data` is the summary at the new depth.
#'
#' @return `list(file, table, rows_total, cmd, warnings)`: the CSV file's
#'         name inside `out_dir`, the first `max_rows` rows as a data frame
#'         with plain column names, the number of rows in all, the rbiom
#'         call that makes the table, and what rbiom warned about. Also
#'         `title` if the table names its model, `methods` (see
#'         `result_methods()`), and `rare` and `data` as from `work_plot()`.
#' @noRd
work_stats <- function (
    ctx, full, rare, out_dir, stats_fn, stats_args,
    subset_args = list(), depth = NULL, max_rows = 50L, checked = TRUE,
    keys = c("args", "samples"), keep_depth = FALSE ) {

  worker_init(ctx)

  result <- list()

  if (!isTRUE(checked)) {
    data        <- cached_summary(ctx, full, rare)
    stats_args  <- worker_check(keys[[1]], check_fn_args(stats_fn, stats_args, data))
    subset_args <- worker_check(keys[[2]], check_subset_args(subset_args, data))
    result[['data']] <- data
  }

  rarefied <- if (!is.null(depth)) rarefy_to(ctx, full, rare, depth)

  if (!is.null(rarefied)) {
    rare             <- file.path(ctx[['files_dir']], rarefied[['rare']][['file']])
    result[['rare']] <- rarefied[['rare']]
    if (isTRUE(keep_depth))
      result[['data']] <- cached_summary(ctx, full, rare, rare_biom = rarefied[['rare_biom']])
  }

  biom <- read_biom(ctx, if (plot_sample_set(stats_fn) == "full") full else rare)
  rare_depth <- if (plot_sample_set(stats_fn) == "rare") biom$depth
  biom <- subset_biom(biom, subset_args)

  if (biom$n_samples == 0)
    stop_user(
      if (isTRUE(keep_depth)) "No samples are left. Loosen the sample filter, or lower the depth."
      else                    "No samples are left to test. Loosen `samples`, or lower `depth`." )

  stats_args[['biom']] <- biom


  #________________________________________________________
  # Run the test. What rbiom warns about (comparisons it
  # could not compute, say) is part of the answer.
  #________________________________________________________
  warnings <- character(0)

  failed <- if (schema_functions[[stats_fn]][['use']] == "table") "The table could not be made." else "The statistics could not be computed."

  stats <- with_user_errors(failed, withCallingHandlers(
    expr    = with_cpus(ctx, base::getExportedValue("rbiom", stats_fn), stats_args),
    warning = function (w) {
      warnings <<- c(warnings, plain_message(w))
      invokeRestart("muffleWarning")
    }))

  table <- as.data.frame(stats, stringsAsFactors = FALSE)
  # (A table can have a column for each group of a field, named by the
  # user's data: two of them may come out the same.)
  names(table) <- make.unique(gsub(".", "_", sub("^\\.", "", names(table)), fixed = TRUE), sep = "_")


  #________________________________________________________
  # The whole table goes into a file; the result carries
  # its first rows.
  #________________________________________________________
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  file <- sprintf("%s_%s.csv", stats_fn, random_string(10))
  atomic_write(file.path(out_dir, file), function (tmp) write.csv(table, tmp, row.names = FALSE, na = ""))

  title <- attr(stats, 'tbl_sum', exact = TRUE)

  c(result, list(
    file       = file,
    table      = head(table, max_rows),
    rows_total = nrow(table),
    cmd        = paste(as.character(attr(stats, 'cmd', exact = TRUE)), collapse = "\n"),
    title      = if (!is.null(title)) as.list(title),
    methods    = result_methods(stats, rare_depth, subset_args),
    warnings   = unique(warnings) ))
}
