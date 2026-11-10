

#______________________________________________________________________________
#' Names of metadata fields
#' @return list(default, options)
#' @noRd
api_metadata_fields <- function (REQ, mode="all") {
  
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  md <- get_biom_component(REQ, rare_bf_id, "metadata")
  
  
  #________________________________________________________
  # Format to be compatible with selectize.js
  #________________________________________________________
  options <- data.frame(
    'value' = colnames(md),
    'class' = as.vector(sapply(colnames(md), function (x) { 
      ifelse(is.numeric(md[[x]]), "numeric", "categorical") })) )
  
  
  #________________________________________________________
  # Filter to only numeric or categorical column types
  #________________________________________________________
  if (identical(mode, 'numeric') || identical(mode, 'categorical'))
    options <- options[options[['class']] == mode,,drop=FALSE]
  
  
  #________________________________________________________
  # Select a default value
  #________________________________________________________
  default <- NULL
  
  
  return (list(default = default, options = options))
}



#______________________________________________________________________________
#' Return options for a categorical metadata column
#' @return list(default, options)
#' @noRd
api_metadata_levels <- function (REQ, field) {
  
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  md <- get_biom_component(REQ, rare_bf_id, "metadata")
  
  if (!is_one_of(field, colnames(md))) stop_user("Unknown metadata field.")
  if (!is.factor(md[[field]]))         stop_user("That metadata field is not categorical.")
  
  
  #________________________________________________________
  # Format to be compatible with selectize.js
  #________________________________________________________
  options <- data.frame(
    value = levels(md[[field]])
  )
  
  
  #________________________________________________________
  # Select a default value
  #________________________________________________________
  default <- head(options[['value']], 3)
  
  
  return (list(default = default, options = options))
}



#______________________________________________________________________________
#' Return options for a numeric metadata column
#' @return list(min, max)
#' @noRd
api_metadata_minmax <- function (REQ, field) {
  
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  md <- get_biom_component(REQ, rare_bf_id, "metadata")
  
  if (!is_one_of(field, colnames(md))) stop_user("Unknown metadata field.")
  if (!is.numeric(md[[field]]))        stop_user("That metadata field is not numeric.")
  
  
  colvals <- md[[field]]
  colvals <- colvals[!is.na(colvals)]
  
  if (length(colvals) == 0)
    return (list(min = NULL, max = NULL))
  
  return (list(min = min(colvals), max = max(colvals)))
}
