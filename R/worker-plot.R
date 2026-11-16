#______________________________________________________________________________
# Drawing a plot. Runs in a worker process; see `R/worker.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' Draw one rbiom plot and save it as an image file.
#'
#' @param ctx          The worker context.
#' @param full,rare    The project's stored BIOM files.
#' @param out_dir      The session's temporary directory, for the image.
#' @param plot_fn      The name of an exposed rbiom plot function.
#' @param plot_args    Its arguments.
#' @param save_args    Arguments for `ggsave()`, from `check_save_args()`.
#' @param subset_args  `list(cat = list(<field> = <values>), num =
#'                     list(<field> = c(lo, hi)))`: samples to keep.
#' @param depth        The rarefaction depth the browser is showing.
#' @param attrs        Also return the statistics table and the R code?
#' @param checked      Were `plot_args` and `subset_args` checked against the
#'                     project in the main process? If not, they are checked
#'                     here first, and the summary used is returned as `data`.
#' @param keys         What the caller calls `plot_args` and `subset_args`,
#'                     for the message when one of them fails that check.
#'
#' @return `list(file)`, the image's name inside `out_dir`. If the project
#'         had to be rarefied to `depth` first, also `rare` and `data` (see
#'         `work_rarefy()`). With `attrs`, also `stats_table`, `stats_title`,
#'         `code`, `caption` (the figure's caption as text) and `methods`
#'         (`list(text, references)`, from `result_methods()`).
#' @noRd
work_plot <- function (
    ctx, full, rare, out_dir, plot_fn, plot_args, save_args,
    subset_args = list(), depth = NULL, attrs = FALSE, checked = TRUE,
    keys = c("plot_args", "subset_args") ) {

  worker_init(ctx)

  result <- list()


  #________________________________________________________
  # Finish checking the arguments, if the main process did
  # not have what it takes.
  #________________________________________________________
  if (!isTRUE(checked)) {
    data        <- cached_summary(ctx, full, rare)
    plot_args   <- worker_check(keys[[1]], check_fn_args(plot_fn, plot_args, data))
    subset_args <- worker_check(keys[[2]], check_subset_args(subset_args, data))
    result[['data']] <- data
  }


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
  biom <- read_biom(ctx, if (plot_sample_set(plot_fn) == "full") full else rare)
  rare_depth <- if (plot_sample_set(plot_fn) == "rare") biom$depth
  biom <- subset_biom(biom, subset_args)

  plot_args           <- present_looks(plot_fn, plot_args, biom)
  plot_args[['biom']] <- biom


  #________________________________________________________
  # Generate the plot.
  #________________________________________________________
  plot_fun <- base::getExportedValue("rbiom", plot_fn)

  p <- with_user_errors("The plot could not be made.", with_cpus(ctx, plot_fun, plot_args))

  # rbiom's caption says what the figure was made from and how. It is
  # returned as text, and in the image its lines are broken to fit.
  caption <- plot_caption(p)
  methods <- if (isTRUE(attrs)) result_methods(p, rare_depth, subset_args)
  p       <- fit_captions(p, save_args)


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
    tryCatch(
      # (A failed drawing also warns that its device was closed.)
      expr  = suppressWarnings(do.call(ggsave, c(list(filename = tmp), save_args))),
      error = function (e) {
        # No room is left for the panels once the legend, labels and
        # caption are in place: that is the request's doing.
        if (grepl("zero dimension|margins too large|too small", conditionMessage(e)))
          stop_user("The image is too small for this figure. Make it larger, or lower its resolution.")
        stop(e)
      })
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

    if (!is.null(caption))
      result[['caption']] <- unbox(caption)

    if (!is.null(methods))
      result[['methods']] <- methods
  }

  return (result)
}


#______________________________________________________________________________
#' A figure's caption as text: what rbiom wrote under the figure about the
#' counts it was made from and the methods used. One sentence or more per
#' line. A figure of several panels (a patchwork, as `rare_multiplot()`
#' returns) has a caption under each; they follow each other here.
#' @return A string, or `NULL` if the figure has no caption.
#' @noRd
plot_caption <- function (p) {

  captions <- function (p) c(
    if (inherits(p, "patchwork")) unlist(lapply(p$patches$plots, captions)),
    tryCatch(p$labels$caption, error = function (e) NULL) )

  lines <- unlist(lapply(captions(p), function (caption) {
    if (is_scalar_character(caption) && !is.na(caption)) strsplit(caption, "\n", fixed = TRUE)[[1]]
  }))

  lines <- unique(trimws(lines))
  lines <- lines[nzchar(lines)]

  if (length(lines) == 0) return (NULL)

  paste(lines, collapse = "\n")
}


#______________________________________________________________________________
#' Break the lines of a figure's caption so that they fit the image.
#'
#' ggplot2 draws each line of a caption as it is given, and what is wider
#' than the image is cut off at its edge. rbiom cannot know how wide the
#' image will be; here it is known. The text is measured in the caption's
#' own font and broken between words.
#'
#' A figure of several panels is only touched when its panels are one above
#' the other, each as wide as the image.
#'
#' @param p          A plot from rbiom.
#' @param save_args  The image settings, from `check_save_args()`.
#' @return The plot, its caption broken into more lines where it has to be.
#'         Unchanged if anything about it is not as expected.
#' @noRd
fit_captions <- function (p, save_args) {

  inches <- save_args[['width']] * save_args[['scale']] /
    switch(save_args[['units']], px = save_args[['dpi']], `in` = 1, cm = 2.54, mm = 25.4)

  fit <- function (p) {

    if (inherits(p, "patchwork")) {
      if (!identical(as.numeric(p$patches$layout$ncol), 1)) return (p)
      p$patches$plots <- lapply(p$patches$plots, fit)
    }

    caption <- p$labels$caption
    if (!is_scalar_character(caption) || is.na(caption) || !nzchar(caption)) return (p)

    theme  <- ggplot2::theme_get() + p$theme
    text   <- ggplot2::calc_element("plot.caption", theme)
    margin <- as.numeric(ggplot2::calc_element("plot.margin", theme))

    # The room for a line, in points: the image less the plot's left and
    # right margins, and a little more, since a PDF's font is not quite
    # the one measured here.
    room <- (inches * 72 - sum(margin[c(2, 4)])) * 0.97

    # (rbiom's captions are in plain type, which is what is measured.)
    width <- function (x) systemfonts::string_width(x, family = text$family %||% "", size = text$size, res = 72)

    lines <- unlist(lapply(strsplit(caption, "\n", fixed = TRUE)[[1]], wrap_line, room = room, width = width))

    p$labels$caption <- paste(lines, collapse = "\n")
    p
  }

  tryCatch(fit(p), error = function (e) p)
}


#' Break one line of text between words into lines no wider than `room`.
#' A single word that is wider stays whole.
#' @param width  A function that measures strings, in the units of `room`.
#' @return A character vector of lines.
#' @noRd
wrap_line <- function (line, room, width) {

  if (!nzchar(line) || width(line) <= room) return (line)

  words <- strsplit(line, " ", fixed = TRUE)[[1]]
  lines <- character(0)
  now   <- words[[1]]

  for (word in words[-1]) {
    longer <- paste(now, word)
    if (width(longer) <= room) { now <- longer; next }
    lines <- c(lines, now)
    now   <- word
  }

  c(lines, now)
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
      biom <- keep_samples(biom, x)
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
      biom <- keep_samples(biom, x)
    }

  return (biom)
}


#' Give an rbiom object a metadata table with fewer rows. rbiom drops the
#' samples that are no longer in it, and warns that it did; here that is the
#' whole point.
#' @noRd
keep_samples <- function (biom, metadata) {
  suppressWarnings(biom$metadata <- metadata)
  biom
}



#______________________________________________________________________________
#' Keep colors, shapes and patterns only for the groups that are in the data.
#'
#' A color, shape or pattern can be given for each value of a field by name
#' (`colors = c(Saliva = "#4477aa", Stool = "#ee6677")`). rbiom refuses a
#' name that is not among the field's values in the data it is handed, and
#' a value can be missing there for reasons the person who chose the colors
#' cannot see: the sample filter, on this field or any other, or the
#' rarefaction depth, left that group with no samples. So the names of
#' groups that are not in the data are dropped, and the figure is drawn
#' with the rest.
#'
#' Only arguments that rbiom's description says are given to the values of a
#' field (`by`) are touched, and only where they are named. Where the field's
#' values are compared in pairs (the beta diversity plots) the groups are
#' pairs that only rbiom works out, and nothing is changed.
#'
#' @param plot_fn    The name of an exposed rbiom plot function.
#' @param plot_args  Its arguments, checked.
#' @param biom       The data the plot is made from, after the sample filter.
#' @return `plot_args`, with those names dropped. An argument left with no
#'         name at all is removed, so rbiom chooses for itself.
#' @noRd
present_looks <- function (plot_fn, plot_args, biom) {

  params <- schema_params(plot_fn)

  for (name in intersect(names(plot_args), names(params))) {

    p     <- params[[name]]
    value <- plot_args[[name]]

    if (!identical(p[['type']], "aesthetic") || is.null(p[['by']])) next
    if (is.null(names(value)) || !all(nzchar(names(value))))         next

    # The field the values belong to: what the request says, else the
    # parameter it follows by default (`stat.by` is the same as `x`).
    by <- params[[p[['by']]]]
    if (is.null(by) || !identical(by[['type']], "field") || !is.null(by[['ops']])) next

    field <- if (by[['name']] %in% names(plot_args)) plot_args[[by[['name']]]]
             else if (!is.null(by[['default_expr']])) plot_args[[by[['default_expr']]]]
    if (!is_scalar_character(field) || !(field %in% colnames(biom$metadata))) next

    present <- unique(as.character(biom$metadata[[field]]))
    value   <- value[names(value) %in% present]

    plot_args[name] <- if (length(value) > 0) list(value) else NULL
  }

  plot_args
}
