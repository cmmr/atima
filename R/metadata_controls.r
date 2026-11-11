#______________________________________________________________________________
# Metadata field lists for the plot controls.
#
# The `api_*()` handlers run in the main process and only describe a job on
# the session's rarefied BIOM file. `metadata_fields()`, `metadata_levels()`
# and `metadata_minmax()` are the pure parts a worker applies to the
# metadata table (`work_metadata_*()` in `R/worker.R`).
#______________________________________________________________________________


#' A job on the session's rarefied BIOM file.
#' @noRd
rare_biom_job <- function (REQ, fn, ...) {
  job(fn, list(
    ctx = worker_ctx(REQ[['CONFIG']]),
    src = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
    ... ))
}


#______________________________________________________________________________
#' Names of metadata fields
#' @return list(default, options)
#' @noRd
api_metadata_fields <- function (REQ, mode="all") {
  rare_biom_job(REQ, "work_metadata_fields", mode = mode)
}


#______________________________________________________________________________
#' Return options for a categorical metadata column
#' @return list(default, options)
#' @noRd
api_metadata_levels <- function (REQ, field) {
  rare_biom_job(REQ, "work_metadata_levels", field = field)
}


#______________________________________________________________________________
#' Return options for a numeric metadata column
#' @return list(min, max)
#' @noRd
api_metadata_minmax <- function (REQ, field) {
  rare_biom_job(REQ, "work_metadata_minmax", field = field)
}


#______________________________________________________________________________
#' Metadata field names and classes, in the format selectize.js expects.
#'
#' @param md    The metadata table.
#' @param mode  `"all"`, or only the `"numeric"` or `"categorical"` fields.
#' @return list(default, options)
#' @noRd
metadata_fields <- function (md, mode = "all") {

  options <- data.frame(
    'value' = colnames(md),
    'class' = as.vector(sapply(colnames(md), function (x) {
      ifelse(is.numeric(md[[x]]), "numeric", "categorical") })) )

  if (identical(mode, 'numeric') || identical(mode, 'categorical'))
    options <- options[options[['class']] == mode,,drop=FALSE]

  return (list(default = NULL, options = options))
}


#______________________________________________________________________________
#' The values of a categorical metadata field, in the format selectize.js
#' expects, with the first three selected.
#' @return list(default, options)
#' @noRd
metadata_levels <- function (md, field) {

  if (!is_one_of(field, colnames(md))) stop_user("Unknown metadata field.")
  if (!is.factor(md[[field]]))         stop_user("That metadata field is not categorical.")

  options <- data.frame(value = levels(md[[field]]))
  default <- head(options[['value']], 3)

  return (list(default = default, options = options))
}


#______________________________________________________________________________
#' The lowest and highest value of a numeric metadata field.
#' @return list(min, max)
#' @noRd
metadata_minmax <- function (md, field) {

  if (!is_one_of(field, colnames(md))) stop_user("Unknown metadata field.")
  if (!is.numeric(md[[field]]))        stop_user("That metadata field is not numeric.")

  colvals <- md[[field]]
  colvals <- colvals[!is.na(colvals)]

  if (length(colvals) == 0)
    return (list(min = NULL, max = NULL))

  return (list(min = min(colvals), max = max(colvals)))
}
