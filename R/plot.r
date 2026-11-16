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
#'         and with `attrs`: stats_table, code, stats_title, caption)
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
    cpus   = rbiom_cpus(plot_fn),
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
        resp[['caption']]     <- result[['caption']]
        resp[['code']]      <- c(
          list('file' = unbox(sprintf("%s/%s.%s", REQ[['SESSION']][['draft_key']], plot_sample_set(plot_fn), code_biom_format(known_summary(REQ))))),
          result[['code']] )
      }

      resp
    })
}


#______________________________________________________________________________
#' Where the session's plot stands, for the browser to show while it waits
#' for the answer of `/api/plot`.
#'
#' @return `list(state)`: `"queued"` with `place` (1 is next) and `waiting`
#'         (jobs in the queue), `"running"`, or `"none"` when no plot of
#'         this session is waiting or being drawn.
#' @noRd
api_plot_status <- function (REQ) {

  pool <- REQ[['POOL']]

  if (is.null(pool)) return (list(state = unbox("none")))

  lapply(pool_place(pool, job_key(REQ[['SESSION']][['session_id']], "/api/plot")), unbox)
}


#' Which of a project's two BIOM files an rbiom function is given. rbiom says
#' which counts each function wants: the rarefaction plots need the depths
#' before rarefying, and the differential abundance model accounts for depth
#' itself; everything else compares samples at one depth.
#' @return `"full"` or `"rare"`.
#' @noRd
plot_sample_set <- function (plot_fn) {
  if (identical(rbiom_schema()[[plot_fn]][['counts']], "unrarefied")) "full" else "rare"
}
