#______________________________________________________________________________
#' Generate a plot for the active project.
#'
#' The main-process part: tidy the arguments, then hand the drawing to
#' `work_plot()` (`R/worker-plot.R`).
#'
#' @return list(image_url, width, height, ..., BIOM (if the depth changed),
#'         and with `attrs`: stats_table, code, stats_title)
#' @noRd
api_plot <- function (
    REQ, plot_fn, plot_args, depth,
    save_args = list(), subset_args = list(), attrs = FALSE) {

  # `plot_fn` is one of the names listed in the route table, so it is safe
  # to look up in rbiom. The contents of `plot_args` and `subset_args` are
  # checked by rbiom and the worker (and by the step 6 schema).
  plot_args   <- as.list(plot_args)
  save_args   <- plot_save_args(as.list(save_args))
  subset_args <- as.list(subset_args)


  #________________________________________________________
  # Numbers are integers by default; change to numeric.
  #________________________________________________________
  for (i in seq_along(plot_args))
    if (is.integer(plot_args[[i]]))
      plot_args[[i]] %<>% as.numeric()


  #________________________________________________________
  # JSON passes named c() as a list(). Change back to c().
  #________________________________________________________
  for (i in c('color.by', 'shape.by', 'pattern.by'))
    if (hasName(plot_args, i))
      for (j in seq_along(plot_args[[i]]))
        if (is.list(plot_args[[i]][[j]][['values']]))
          plot_args[[i]][[j]][['values']] %<>% unlist()


  #________________________________________________________
  # Simplify *.by args.
  #________________________________________________________
  for (i in grep("\\.by$", names(plot_args)))
    for (j in seq_along(plot_args[[i]])) {
      val <- plot_args[[i]][[j]]
      if (is.list(val) && length(val) == 1)
        if (hasName(val, 'values') || hasName(val, 'range'))
          plot_args[[i]][[j]] <- val[[1]]
    }


  job(
    fn   = "work_plot",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      full        = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare        = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      out_dir     = REQ[['SESSION']][['server_temp']],
      plot_fn     = plot_fn,
      plot_args   = plot_args,
      save_args   = save_args,
      subset_args = subset_args,
      depth       = depth,
      attrs       = isTRUE(attrs) ),
    finish = function (result) {

      resp <- list()

      # rare_multiplot can change the depth, and so can a plot that follows
      # a cancelled call to api_rarefy().
      if (!is.null(result[['rare']])) {
        update_draft(REQ, rare = result[['rare']])
        resp[['BIOM']] <- biom_reply(REQ, result[['data']])
      }

      resp %<>% c(list(
        'image_url' = unbox(paste0(REQ[['SESSION']][['client_temp']], "/", result[['file']])),
        'width'     = unbox(save_args[['width']]),
        'height'    = unbox(save_args[['height']]),
        'scale'     = unbox(save_args[['scale']]),
        'dpi'       = unbox(save_args[['dpi']]),
        'device'    = unbox(save_args[['device']]),
        'units'     = unbox(save_args[['units']]),
        'attrs'     = unbox(isTRUE(attrs)) ))

      if (isTRUE(attrs)) {

        sample_set <- ifelse(plot_fn == "rare_multiplot", "full", "rare")

        resp[['stats_table']] <- result[['stats_table']]
        resp[['stats_title']] <- result[['stats_title']]
        resp[['code']]        <- c(
          list('file' = unbox(sprintf("%s/%s.json", REQ[['SESSION']][['draft_key']], sample_set))),
          result[['code']] )
      }

      resp
    })
}


#______________________________________________________________________________
#' Check the image settings a plot request came with, and fill in defaults.
#' @return A list of arguments for `ggsave()`.
#' @noRd
plot_save_args <- function (save_args) {

  save_params <- setdiff(formalArgs(ggsave), c("bg", "limitsize", "filename", "path", "plot", "..."))
  save_args   <- save_args[intersect(names(save_args), save_params)]

  save_args[['scale']]  <- ifelse(is.null(save_args[['scale']]),  1,   as.numeric(save_args[['scale']]))
  save_args[['width']]  <- ifelse(is.null(save_args[['width']]),  400, as.numeric(save_args[['width']]))
  save_args[['height']] <- ifelse(is.null(save_args[['height']]), 300, as.numeric(save_args[['height']]))
  save_args[['dpi']]    <- ifelse(is.null(save_args[['dpi']]),    300, as.numeric(save_args[['dpi']]))
  if (is.null(save_args[['device']])) save_args[['device']] <- "png"
  if (is.null(save_args[['units']]))  save_args[['units']]  <- "px"

  if (!is_one_of(save_args[['device']], c("eps", "ps", "tex", "pdf", "jpeg", "tiff", "png", "bmp", "svg", "wmf")))
    stop_user("Unknown image format.")

  if (!is_one_of(save_args[['units']], c("in", "cm", "mm", "px")))
    stop_user("Unknown image size units.")

  for (i in seq_len(length(save_args)))
    if (length(save_args[[i]]) != 1 || is.na(save_args[[i]]))
      stop_user("Invalid image setting '", names(save_args)[[i]], "'.")

  save_args
}
