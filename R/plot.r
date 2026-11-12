#______________________________________________________________________________
#' Generate a plot for the active project.
#'
#' The main-process part. The router has already checked every argument
#' against the schema (`R/schema.R`), so all that is left is to hand the
#' drawing to `work_plot()` (`R/worker-plot.R`).
#'
#' @param plot_fn      The name of an exposed rbiom plot function.
#' @param plot_args    Its arguments, as `check_fn_args()` returned them.
#' @param depth        The rarefaction depth the browser is showing.
#' @param save_args    Image settings, from `check_save_args()`.
#' @param subset_args  The samples to keep, from `check_subset_args()`.
#' @param attrs        Also return the statistics table and the R code?
#'
#' @return list(image_url, width, height, ..., BIOM (if the depth changed),
#'         and with `attrs`: stats_table, code, stats_title)
#' @noRd
api_plot <- function (
    REQ, plot_fn, plot_args, depth,
    save_args = check_save_args(list()), subset_args = list(), attrs = FALSE) {

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
      attrs       = isTRUE(attrs),
      checked     = !is.null(known_summary(REQ)) ),
    finish = function (result) {

      resp <- list()

      # rare_multiplot can change the depth, and so can a plot that follows
      # a cancelled call to api_rarefy().
      if (!is.null(result[['rare']])) {
        update_draft(REQ, rare = result[['rare']])
        resp[['BIOM']] <- biom_reply(REQ, result[['data']])

      } else if (!is.null(result[['data']])) {
        # The worker had to look the summary up to check the arguments.
        memo_set(REQ, result[['data']])
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

        resp[['stats_table']] <- result[['stats_table']]
        resp[['stats_title']] <- result[['stats_title']]
        resp[['code']]        <- c(
          list('file' = unbox(sprintf("%s/%s.json", REQ[['SESSION']][['draft_key']], plot_sample_set(plot_fn)))),
          result[['code']] )
      }

      resp
    })
}


#' Which of a project's two BIOM files a plot function is given: the
#' rarefaction plots show the counts before rarefying, everything else after.
#' @return `"full"` or `"rare"`.
#' @noRd
plot_sample_set <- function (plot_fn) {
  if (identical(schema_functions[[plot_fn]][['area']], "rarefaction")) "full" else "rare"
}
