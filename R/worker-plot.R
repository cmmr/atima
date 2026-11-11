#______________________________________________________________________________
# Drawing a plot. Runs in a worker process; see `R/worker.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Draw one rbiom plot and save it as an image file.
#'
#' @param ctx          The worker context.
#' @param full,rare    The project's stored BIOM files.
#' @param out_dir      The session's temporary directory, for the image.
#' @param plot_fn      The name of an rbiom plot function, from the route
#'                     table's list.
#' @param plot_args    Its arguments.
#' @param save_args    Arguments for `ggsave()`, from `plot_save_args()`.
#' @param subset_args  `list(cat = list(<field> = <values>), num =
#'                     list(<field> = c(lo, hi)))`: samples to keep.
#' @param depth        The rarefaction depth the browser is showing.
#' @param attrs        Also return the statistics table and the R code?
#'
#' @return `list(file)`, the image's name inside `out_dir`. If the project
#'         had to be rarefied to `depth` first, also `rare` and `data` (see
#'         `work_rarefy()`). With `attrs`, also `stats_table`, `stats_title`
#'         and `code`.
#' @noRd
work_plot <- function (
    ctx, full, rare, out_dir, plot_fn, plot_args, save_args,
    subset_args = list(), depth = NULL, attrs = FALSE ) {

  worker_init(ctx)

  result <- list()


  #________________________________________________________
  # Keep the back end in step with the depth on screen.
  #________________________________________________________
  rarefied <- if (!is.null(depth)) rarefy_to(ctx, full, rare, depth)

  if (!is.null(rarefied)) {
    rare             <- file.path(ctx[['files_dir']], rarefied[['rare']][['file']])
    result[['rare']] <- rarefied[['rare']]
    result[['data']] <- cached_summary(ctx, full, rare, rare_biom = rarefied[['rare_biom']])
  }


  #________________________________________________________
  # The BIOM object, limited to the samples asked for.
  #________________________________________________________
  biom <- read_biom(ctx, if (plot_fn == "rare_multiplot") full else rare)
  biom <- subset_biom(biom, subset_args)

  plot_args[['biom']] <- biom


  #________________________________________________________
  # Generate the plot.
  #________________________________________________________
  plot_fun <- base::getExportedValue("rbiom", plot_fn)

  p <- with_user_errors("The plot could not be made.", with_cpus(ctx, plot_fun, plot_args))


  #________________________________________________________
  # Save the figure in the requested format, under a new
  # name, appearing all at once.
  #________________________________________________________
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  device <- save_args[['device']]
  file   <- sprintf("plot_%s.%s", random_string(10), device)

  save_args[['plot']]      <- p
  save_args[['limitsize']] <- FALSE

  # Raster images are drawn by ragg: well anti-aliased, and the same on
  # every platform, with no need for X11 or cairo on the server.
  save_args[['device']] <- switch(
    EXPR = device,
    png  = ragg::agg_png,
    jpeg = ragg::agg_jpeg,
    tiff = ragg::agg_tiff,
    device )

  atomic_write(file.path(out_dir, file), function (tmp) {
    do.call(ggsave, c(list(filename = tmp), save_args))
  })

  result[['file']] <- file


  #________________________________________________________
  # Optionally return stats, code, etc
  #________________________________________________________
  if (isTRUE(attrs)) {

    stats <- attr(p, 'stats', exact = TRUE)

    if (!is.null(stats)) {
      stats_cols <- colnames(stats)
      stats_cols <- sub("^\\.", "", stats_cols)
      stats_cols <- gsub(".", "_", stats_cols, fixed = TRUE)
      result[['stats_table']] <- as.data.frame(stats)
      colnames(result[['stats_table']]) <- stats_cols
    }

    result[['code']] <- list(

      'rbiom' = unbox(attr(p, 'cmd', exact = TRUE)),

      'ggplot2' = unbox(paste0(
        sprintf("p    <- %s\n\n",     attr(p, 'cmd',  exact = TRUE)),
        sprintf("data <- p$data\n%s", attr(p, 'code', exact = TRUE)) )) )

    if (!is.null(stats))
      result[['code']][['stats']] <- unbox(attr(stats, 'code', exact = TRUE))

    stats_title <- attr(stats, 'tbl_sum', exact = TRUE)
    if (!is.null(stats_title))
      result[['stats_title']] <- lapply(stats_title, unbox)
  }

  return (result)
}


#______________________________________________________________________________
#' Keep only the samples whose metadata matches.
#'
#' @param biom         An rbiom object.
#' @param subset_args  `cat`: for each categorical field, the values to
#'                     keep, in the order to show them. `num`: for each
#'                     numeric field, the lowest and highest value to keep.
#' @return The rbiom object with fewer samples.
#' @noRd
subset_biom <- function (biom, subset_args) {

  cat_args <- subset_args[['cat']]
  num_args <- subset_args[['num']]

  if (is.list(cat_args))
    for (i in seq_along(cat_args)) {

      col_name   <- names(cat_args)[[i]]
      col_values <- cat_args[[i]]

      if (!is_one_of(col_name, biom$fields))
        stop_user("Unknown metadata field in subset.")

      if (!is.character(col_values) || length(col_values) == 0 || !is.null(names(col_values)))
        stop_user("Invalid subset values for '", col_name, "'.")

      x <- biom$metadata
      x[[col_name]] %<>% factor(levels = col_values)
      x <- x[!is.na(x[[col_name]]),,drop=FALSE]
      biom$metadata <- x
    }

  if (is.list(num_args))
    for (i in seq_along(num_args)) {

      col_name  <- names(num_args)[[i]]
      col_range <- num_args[[i]]

      if (!is_one_of(col_name, biom$fields))
        stop_user("Unknown metadata field in subset.")

      if (!is.numeric(col_range) || length(col_range) != 2 || anyNA(col_range) || !is.null(names(col_range)))
        stop_user("Invalid subset range for '", col_name, "'.")

      x    <- biom$metadata
      vals <- x[[col_name]]
      vals[which(vals < col_range[[1]] | vals > col_range[[2]])] <- NA
      x <- x[!is.na(vals),,drop=FALSE]
      biom$metadata <- x
    }

  return (biom)
}
