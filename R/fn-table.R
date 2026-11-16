#______________________________________________________________________________
# A table that an rbiom function makes from the open project, where the
# table is the result itself: the most abundant taxa, the taxa groups share.
# (A statistics table comes with its figure, through `api_plot()`.)
#______________________________________________________________________________


# The most rows of a table sent to the browser. The CSV file has them all.
table_rows_max <- 2000L


#______________________________________________________________________________
#' Make a table for the active project.
#'
#' The main-process part, like `api_plot()`: the router has checked every
#' argument against the schema, and `work_stats()` (`R/worker-stats.R`) does
#' the rest.
#'
#' @param table_fn     The name of an exposed rbiom function of use `table`.
#' @param table_args   Its arguments, as `check_fn_args()` returned them.
#' @param depth        The rarefaction depth the browser is showing.
#' @param subset_args  The samples to keep, from `check_subset_args()`.
#'
#' @return list(table, rows_total, file_url, code, warnings), and BIOM if
#'         the depth changed. `table` is the first `table_rows_max` rows;
#'         `file_url` is the whole table as a CSV file.
#' @noRd
api_table <- function (REQ, table_fn, depth, table_args = list(), subset_args = list()) {

  job(
    fn   = "work_stats",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      full        = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare        = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      out_dir     = REQ[['SESSION']][['server_temp']],
      stats_fn    = table_fn,
      stats_args  = table_args,
      subset_args = subset_args,
      depth       = depth,
      max_rows    = table_rows_max,
      checked     = !is.null(known_summary(REQ)),
      keys        = c("table_args", "subset_args"),
      keep_depth  = TRUE ),
    finish = function (result) {

      resp <- list()

      # As for a plot: the depth on screen may not have been the stored one.
      if (!is.null(result[['rare']])) {
        update_draft(REQ, rare = result[['rare']])
        resp[['BIOM']] <- biom_reply(REQ, result[['data']])

      } else if (!is.null(result[['data']])) {
        memo_set(REQ, result[['data']])
      }

      c(resp, list(
        'table'      = result[['table']],
        'rows_total' = unbox(result[['rows_total']]),
        'file_url'   = unbox(paste0(REQ[['SESSION']][['client_temp']], "/", result[['file']])),
        'code'       = list(
          'file' = unbox(sprintf("%s/%s.json", REQ[['SESSION']][['draft_key']], plot_sample_set(table_fn))),
          'cmd'  = unbox(result[['cmd']]) ),
        'warnings'   = as.character(result[['warnings']]) ))
    })
}
