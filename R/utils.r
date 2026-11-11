#______________________________________________________________________________
#' Allow-list check: is `x` a single string that appears in `choices`?
#' 
#' Unlike `rlang::is_string(x, string)`, a `NULL` or empty `choices` matches
#' nothing, so a missing allow-list can never let a value through.
#' @return TRUE or FALSE
#' @noRd
is_one_of <- function (x, choices) {
  if (!is.character(x) || length(x) != 1 || is.na(x)) return (FALSE)
  if (!is.character(choices))                         return (FALSE)
  return (x %in% choices)
}





#______________________________________________________________________________
#' Shorthand for replacing NAs with something else.
#' @noRd
if.na <- function (x, replacement) {
  if (!is.na(x))                 return (x)
  if (!is.function(replacement)) return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Shorthand for replacing NULLs with something else.
#' @noRd
if.null <- function (x, replacement) {
  if (!is.null(x))               return (x)
  if (!is.function(replacement)) return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Shorthand for replacing empty character strings with something else.
#' @noRd
if.blank <- function (x, replacement) {
  if (identical(nzchar(x), TRUE)) return (x)
  if (!is.function(replacement))  return (replacement)
  return (replacement())
}

#______________________________________________________________________________
#' Convert (x, y = 4) to list(x = x, y = 4)
#' @noRd
named_dots <- function (...) {
  
  values <- list(...)
  if (length(values) == 0) return (list())
  
  if (is.null(names(values)) || any(names(values) == ""))
    names(values) <- names(exprs_auto_name(substitute(list(...))))[-1]
  
  return (values)
}


#______________________________________________________________________________
#' Generate a random key of lower-case letters and digits, each equally
#' likely, from the operating system's secure random source.
#' @noRd
random_key <- function (len) {

  symbols <- c(letters, 0:9)
  out     <- character(0)

  while (length(out) < len) {
    bytes <- as.integer(rand_bytes(len * 2L))
    # 252 is the largest multiple of 36 that a byte can reach; larger bytes
    # are thrown away so that no symbol is favoured.
    out   <- c(out, symbols[bytes[bytes < 252L] %% 36L + 1L])
  }

  paste(out[seq_len(len)], collapse = "")
}


#______________________________________________________________________________
#' Generate a random alphanumeric string.
#' 
#' First character is a-zA-Z
#' Remaining characters are a-zA-Z0-9
#' @noRd
random_string <- function (len) {
  
  rnd_i <- ceiling(c(
    rand_num(1)       * 52,
    rand_num(len - 1) * 62 ))
  rnd_i <- ifelse(rnd_i == 0, 1, rnd_i) # Very small chance of 0
  
  paste(collapse = "", c(letters, LETTERS, 0:9)[rnd_i])
}
