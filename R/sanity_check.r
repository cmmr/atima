#______________________________________________________________________________
#' Check that the values pass basic sanity checks.
#' @return TRUE/FALSE, with attr('failures')
#' @noRd
sanity_check <- function (..., assert = TRUE, simple = FALSE) {
  
  
  #________________________________________________________
  # Name the unnamed parameters. Example:
  #  from sanity_check(user_id)
  #  to   sanity_check(user_id = user_id)
  #________________________________________________________
  args <- list(...)
  if (is.null(names(args))) {
    names(args) <- all.vars(substitute(list(...)))
  } else if (any(unnamed <- nchar(names(args)) == 0)) {
    names(args)[which(unnamed)] <- all.vars(substitute(list(...)))
  }
  
  
  # If anything gets added to failed, something isn't sane.
  #________________________________________________________
  failed <- list()
  
  for (key in names(args)) {
    val <- args[[key]]
    
    
    # Special cases where NULL is okay
    #________________________________________________________
    if (is.null(val)) {
      if (key == "user_id")              next
      if (key == "parent_id")            next
      if (key == "access_key")           next
      if (key == "jstree_icon")          next
      if (key == "grantor_user_id")      next
      if (key == "parent_collection_id") next
    }
    
    
    # All values must be non-NULL/NA and a vector of length 1
    #________________________________________________________
    if (is.null(val))    { failed[[key]] <- sprintf("%s is NULL",         key); next }
    if (!is.vector(val)) { failed[[key]] <- sprintf("%s is not a vector", key); next }
    if (length(val) > 1) { failed[[key]] <- sprintf("%s length > 1",      key); next }
    if (is.na(val))      { failed[[key]] <- sprintf("%s is NA",           key); next }
    
    trimval <- ifelse(is.character(val), trimws(val), '')
    trimlen <- ifelse(is.character(val), nchar(trimval), 0)
    
    
    
    # Tests for specific types of variables.
    #________________________________________________________
    val_class <- paste(collapse = "/", class(val))
    
    failed[[key]] <- local({
      
      if (key %in% c("title", "jstree_text", "jstree_icon")) {
        if (!is.character(val)) {
          sprintf("%s value should be character, not '%s'.", key, val_class)
        } else if (trimlen < 3) {
          sprintf("Text for %s is too short. Minimum is 3 characters.", key)
        } else if (trimlen > 100) {
          sprintf("Text for %s is too long. Maximum is 100 characters.", key)
        } else { NULL } 
        
      } else if (key == "description") {
        if (!is.character(val)) {
          sprintf("Invalid %s of class '%s'", key, val_class)
        } else if (trimlen > 5000) {
          "Description length must less than 5,000 characters."
        } else { NULL }
        
      } else if (startsWith(key, "is_") || startsWith(key, "has_")) {
        if (!is.logical(val)) {
          sprintf("%s value should be logical, not '%s'.", key, val_class)
        } else { NULL } 
        
      } else if (startsWith(key, "n_")) {
        if (!is.numeric(val)) {
          sprintf("%s value should be numeric, not '%s'.", key, val_class)
        } else if (!val %% 1 == 0) {
          sprintf("%s value should be a whole number, not '%s'.", val)
        } else { NULL }
        
      } else if (endsWith(key, "_token")) {
        if (!is.character(val)) {
          sprintf("Invalid %s of class '%s'", key, val_class)
        } else if (!grepl("^[0-9]+\\.[A-Za-z0-9]{64}$", val)) {
          sprintf("%s doesn't match ^[0-9]+/[A-Za-z0-9]{64}$ : '%s'.", key, val)
        } else { NULL }
        
      } else if (endsWith(key, "_key")) {
        if (!is.character(val)) {
          sprintf("Invalid %s of class '%s'", key, val_class)
        } else if (trimlen < 4 || trimlen > 20) {
          sprintf("%s must be between 4 and 20 characters long : %s", key, val)
        } else if (!grepl("^[A-Za-z0-9\\-]+$", val)) {
          sprintf("%s can only contain alphanumerics and hyphens : '%s'.", key, val)
        } else if (startsWith(val, '-') || endsWith(val, '-')) {
          sprintf("%s cannot start or end with a hyphen : '%s'.", key, val)
        } else if (identical(tolower(trimval), "unsaved")) {
          sprintf("%s cannot be : '%s'.", key, val)
        } else { NULL }
        
      } else if (endsWith(key, "_code")) {
        if (!is.character(val)) {
          sprintf("Invalid %s of class '%s'", key, val_class)
        } else if (!grepl("^[0-9]{6}$", val)) {
          sprintf("%s '%s' doesn't match ^[0-9]{6}$", key, val)
        } else { NULL }
        
      } else if (endsWith(key, "_utc")) {
        if (!is.character(val)) {
          sprintf("Invalid %s of class '%s'", key, val_class)
        } else if (!grepl("^\\d{4}\\-\\d{2}\\-\\d{2}$", val)) {
          sprintf("%s '%s' isn't in YYYY-MM-DD format.", key, val)
        } else { NULL }
        
      } else if (key %in% c("node_id", "parent_node_id")) {
        if (!is.character(val)) {
          sprintf("Invalid node_id of class '%s' instead of character", val_class)
        } else if (identical("#", val)) {
          NULL
        } else if (!grepl("^[PC]\\d+$", val)) {
          sprintf("node_id '%s' doesn't match ^[PC]\\d+$", val)
        } else if (key == "parent_node_id" && !startsWith(val, 'C')) {
          sprintf("Invalid parent_node_id '%s'. Not a collection.", val)
        } else { NULL }
        
      } else if (endsWith(key, "_id")) {
        if (!is.integer(val)) {
          sprintf("Invalid %s of class '%s' instead of integer.", key, val_class)
        } else if (identical(val, 0L)) {
          sprintf("Invalid %s value of 0 (zero).", key)
        } else { NULL }
        
      } else if (key == "email") {
        if (trimlen < 5) {
          "Email must be at least 5 characters."
        } else { NULL }
        
      } else if (key == "affiliation") {
        if (trimlen > 50) {
          "Affiliation must be less than 50 characters."
        } else { NULL }
        
      } else if (key %in% c("password", "new_password")) {
        if (trimlen < 6) {
          "Password must be at least 6 characters."
        } else { NULL }
        
      } else if (key == "full_name") {
        if (trimlen < 3) {
          "Full name must be at least 3 characters."
        } else if (startsWith(tolower(val), "guest ")) {
          "Full name cannot start with 'guest '."
        } else { NULL }
        
      } else if (key == 'median_depth') {
        if (!is.numeric(val)) {
          sprintf("%s must be numeric, not '%s'.", key, val_class)
        } else { NULL }
        
      } else if (key == 'meta_colnames') {
        if (!is.character(val)) {
          sprintf("%s must be character, not '%s'.", key, val_class)
        } else { NULL }
        
      } else if (key == "depth") {
        if (!is.numeric(val)) {
          "Rarefaction depth must be numeric."
        } else if (!is.finite(val)) {
          "Rarefaction depth must be finite."
        } else if (!isTRUE(val > 0)) {
          "Rarefaction depth must greater than 0."
        } else if (!isTRUE(val %% 1 == 0)) {
          "Rarefaction depth must be an integer."
        } else { NULL }
        
      } else if (key == "permissions") {
        if (!val %in% c("none", "view", "edit", "any")) {
          sprintf("Invalid permissions of '%s'. Options are: none, view, edit, or any", val)
        } else { NULL }
        
      } else {
        sprintf("No sanity_check_function for '%s'.", key)
      }
    })
  }
  
  is_sane <- isTRUE(length(failed) == 0)
  attr(is_sane, 'failures') <- failed
  
  if (!is_sane && assert)
    stop(error_details(paste(collapse = "; ", unlist(failed))))
  
  return (is_sane)
}


