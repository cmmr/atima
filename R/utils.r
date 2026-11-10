#______________________________________________________________________________
#' Allow-list check: is `x` a single string that appears in `choices`?
#' 
#' Unlike `rlang::is_string(x, string)`, a `NULL` or empty `choices` matches
#' nothing, so a missing allow-list can never let a value through.
#' @return TRUE or FALSE
is_one_of <- function (x, choices) {
  if (!is.character(x) || length(x) != 1 || is.na(x)) return (FALSE)
  if (!is.character(choices))                         return (FALSE)
  return (x %in% choices)
}





#______________________________________________________________________________
#' Make sure this is a length-one integer or NULL.
#' @return an integer, or NULL.
int <- function (val, assert = TRUE) {
  
  if (is.null(val))
    return (NULL)
  
  if (length(val) != 1) {
    if (isTRUE(assert))
      stop(error_details("value is not length 1"))
    return (NULL)
  }
  
  
  if (!is.integer(val)) {
    val <- try(silent = TRUE, as.integer(val))
    
    if (!is.integer(val) || is.na(val)) {
      if (isTRUE(assert))
        stop(error_details("Can't convert '", val, "' to int."))
      return (NULL)
    }
  }
  
  
  if (val < 1) {
    if (isTRUE(assert))
      stop(error_details("Integer is non-positive."))
    return (NULL)
  }
  
  return (val)
}



#______________________________________________________________________________
#' AJAX response that will trigger a sweetalert pop up.
#' @return <response:swal>
swal <- function (
    ..., icon = 'warning', title = NA, 
    success = NULL, error = NULL, warning = NULL, info = NULL ) {
  
  text <- paste0(success, error, warning, info, ...)
  if (!is.null(success)) icon <- 'success'
  if (!is.null(error))   icon <- 'error'
  if (!is.null(warning)) icon <- 'warning'
  if (!is.null(info))    icon <- 'info'
  
  resp <- response(list(
    'swal' = list(
      'title' = unbox(title), 
      'text'  = unbox(text), 
      'icon'  = unbox(icon) )))
  
  return (resp)
}




#______________________________________________________________________________
#' Shorthand for replacing NAs with something else.
if.na <- function (x, replacement) {
  if (!is.na(x))                 return (x)
  if (!is.function(replacement)) return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Shorthand for replacing NULLs with something else.
if.null <- function (x, replacement) {
  if (!is.null(x))               return (x)
  if (!is.function(replacement)) return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Shorthand for replacing empty character strings with something else.
if.blank <- function (x, replacement) {
  if (identical(nzchar(x), TRUE)) return (x)
  if (!is.function(replacement))  return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Convert (x, y = 4) to list(x = x, y = 4)
named_dots <- function (...) {
  
  values <- list(...)
  if (length(values) == 0) return (list())
  
  if (is.null(names(values)) || any(names(values) == ""))
    names(values) <- names(exprs_auto_name(substitute(list(...))))[-1]
  
  return (values)
}


#______________________________________________________________________________
#' Generate a random alphanumeric string.
#' 
#' First character is a-zA-Z
#' Remaining characters are a-zA-Z0-9
random_string <- function (len) {
  
  rnd_i <- ceiling(c(
    rand_num(1)       * 52,
    rand_num(len - 1) * 62 ))
  rnd_i <- ifelse(rnd_i == 0, 1, rnd_i) # Very small chance of 0
  
  paste(collapse = "", c(letters, LETTERS, 0:9)[rnd_i])
}
