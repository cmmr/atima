#______________________________________________________________________________
#' Build the HTTP response that is handed back to httpuv.
#'
#' @param body      The content. A list is encoded as JSON; a character vector
#'                  is concatenated and sent as HTML; a single integer is taken
#'                  to be the status code. With no body, the standard reason
#'                  phrase for `status` is sent.
#' @param status    An HTTP status code.
#' @param headers   A named list or character vector of HTTP headers.
#' @param ...       Objects made by `header()` or `cookie()`, or name = value
#'                  pairs to add to `headers`. A header object may also be
#'                  given in place of `body` or `status`.
#'
#' @return A list with `body`, `status` and `headers`, of class
#'         `c('response', 'AsIs')`.
#' @noRd
response <- function (body = NULL, status = 200L, headers = NULL, ...) {

  headers <- c(as.list(headers), ...)
  if (inherits(status, 'header')) { headers <- c(status, headers); status <- 200L }
  if (inherits(body,   'header')) { headers <- c(body,   headers); body   <- NULL }

  for (i in seq_along(headers)) {
    headers[[i]] <- as.character(headers[[i]])
    stopifnot(
      valid_string(names(headers)[[i]], ok = '-_'),
      valid_string(headers[[i]], ok = '_ :;.,\\/"\'?!(){}[]@<>=-+*#$&`|~^%')
    )
  }

  if (is_int(body)) { status <- body; body <- NULL }
  status <- as.integer(status)
  stopifnot(status >= 100L, status < 600L)

  if (!inherits(body, c('list', 'json', 'character', 'numeric', 'NULL')))
    stop('`body` must be a list, character, json, or NULL, not ', class(body)[[1]], '.')

  # Set content-type unless it's already set.
  if (!'content-type' %in% tolower(names(headers)))
    headers[['Content-Type']] <- {
      if (inherits(body, c('list', 'json'))) { 'application/json; charset=utf-8' }
      else if (inherits(body, 'character'))  { 'text/html; charset=utf-8'        }
    }

  # Combine multiple 'Access-Control-Expose-Headers' into one.
  aceh <- tolower(names(headers)) == 'access-control-expose-headers'
  if (sum(aceh) > 1) {
    merged  <- paste(collapse = ', ', headers[aceh])
    headers <- headers[!aceh]
    headers[['Access-Control-Expose-Headers']] <- merged
  }

  # Numbers are written in full. jsonlite's default of four decimal places
  # turned every p-value below 0.00005 into 0, and moved the ends of a
  # numeric field's range inside the values it has.
  if (inherits(body, 'list'))               body <- toJSON(body, null = 'null', digits = NA)
  if (inherits(body, c('json', 'numeric'))) body <- as.character(body)
  if (length(body) > 0) { body <- paste0(body, collapse = '')         }
  else                  { body <- code_to_msg[[as.character(status)]] }

  resp <- structure(
    .Data = list(body = body, status = status, headers = headers),
    class = c('response', 'AsIs') )

  return (resp)
}



#______________________________________________________________________________
#' One HTTP response header, for passing to `response()`.
#'
#' @param ...       A single name = value pair. An unnamed variable uses its
#'                  own name, e.g. `header(Location)`.
#' @param expose    Allow javascript in the browser to read this header.
#' @param name,value  Set the header's name and value explicitly.
#'
#' @return A named list of class 'header'.
#' @noRd
header <- function (..., expose = FALSE, name = ...names(), value = ..1) {

  header_name  <- name[[1]] %||% as.character(substitute(...))
  header_value <- as.character(value)

  stopifnot(
    valid_string(header_name,  ok = '-_'),
    valid_string(header_value, ok = '_ :;.,\\/"\'?!(){}[]@<>=-+*#$&`|~^%')
  )

  hdr        <- list(header_value)
  names(hdr) <- header_name

  if (isTRUE(expose))
    hdr <- c(hdr, list('Access-Control-Expose-Headers' = header_name))

  class(hdr) <- 'header'
  return (hdr)

}



#______________________________________________________________________________
#' A `Set-Cookie` header, for passing to `response()`.
#'
#' @param ...          A single name = value pair. An unnamed variable uses
#'                     its own name, e.g. `cookie(auth_token)`.
#' @param max_age      Seconds until the cookie expires. `NULL` makes a
#'                     session cookie. `Inf` is sent as 400 days, the most
#'                     browsers accept.
#' @param domain,path  Limit which requests the cookie is sent with.
#' @param same_site    `'Strict'`, `'Lax'`, or `'None'`.
#' @param secure       Only send over HTTPS.
#' @param http_only    Hide the cookie from javascript.
#' @param partitioned  Use partitioned storage.
#' @param name,value   Set the cookie's name and value explicitly.
#'
#' @return A 'header' object.
#' @noRd
cookie <- function (
    ...,
    max_age = NULL, domain = NULL, path = NULL, same_site = 'Lax',
    secure = FALSE, http_only = FALSE, partitioned = FALSE,
    name = ...names(), value = ..1 ) {

  cookie_name  <- name[[1]] %||% as.character(substitute(...))
  cookie_value <- as.character(value)

  if (identical(max_age, Inf)) max_age <- 34560000L

  stopifnot(
    valid_string(cookie_name,  no = ' ()<>@,;:\\"/[]?={}'),
    valid_string(cookie_value, no = ' ",;\\'),
    is.null(max_age) || is_int(max_age <- as.integer(max_age)),
    valid_string(domain, ok = '.-',                 null_ok = TRUE),
    valid_string(path,   ok = ".-_~!$&'()*+,=:@%/", null_ok = TRUE),
    same_site %in% c('None', 'Lax', 'Strict'),
    is_bool(secure),
    is_bool(http_only),
    is_bool(partitioned)
  )

  cookie_string <- paste(collapse = '; ', c(
    paste0(cookie_name, '=', cookie_value),
    if (!is.null(max_age))  paste0('Max-Age=',  max_age),
    if (!is.null(domain))   paste0('Domain=',   domain),
    if (!is.null(path))     paste0('Path=',     path),
    paste0('SameSite=', same_site),
    if (secure)             'Secure',
    if (http_only)          'HttpOnly',
    if (partitioned)        'Partitioned'
  ))

  hdr <- header(name = 'Set-Cookie', value = cookie_string)

  return (hdr)
}



#______________________________________________________________________________
#' Is `x` a single non-missing integer?
#' @noRd
is_int <- function (x) {
  is.integer(x) && length(x) == 1 && !is.na(x)
}


#______________________________________________________________________________
#' Is `x` a single `TRUE` or `FALSE`?
#' @noRd
is_bool <- function (x) {
  is.logical(x) && length(x) == 1 && !is.na(x)
}


#______________________________________________________________________________
#' Is `x` a single non-empty string made only of permitted characters?
#'
#' @param ok       Characters allowed in addition to letters and digits. When
#'                 given, anything else is rejected.
#' @param no       Characters to reject, in addition to control characters.
#'                 Only used when `ok` is empty.
#' @param null_ok  Accept `NULL`.
#' @noRd
valid_string <- function (x, ok = '', no = '', null_ok = FALSE) {

  if (is.null(x) && null_ok) return (TRUE)
  if (!is_string(x))         return (FALSE)
  if (!nzchar(x))            return (FALSE)

  if (nzchar(ok)) {
    ok <- c(as.raw(c(48:57, 65:90, 97:122)), charToRaw(ok))
    return (all(charToRaw(x) %in% ok))
  }
  else {
    no <- c(as.raw(c(0:31, 127)), charToRaw(no))
    return (!any(charToRaw(x) %in% no))
  }

}



#______________________________________________________________________________
# Reason phrases, used as the body of responses that have none.
code_to_msg <- list(
  '100' = "Continue",
  '101' = "Switching Protocols",
  '102' = "Processing",
  '103' = "Early Hints",
  '200' = "OK",
  '201' = "Created",
  '202' = "Accepted",
  '203' = "Non-Authoritative Information",
  '204' = "No Content",
  '205' = "Reset Content",
  '206' = "Partial Content",
  '207' = "Multi-Status",
  '208' = "Already Reported",
  '226' = "IM Used",
  '300' = "Multiple Choices",
  '301' = "Moved Permanently",
  '302' = "Found",
  '303' = "See Other",
  '304' = "Not Modified",
  '307' = "Temporary Redirect",
  '308' = "Permanent Redirect",
  '400' = "Bad Request",
  '401' = "Unauthorized",
  '402' = "Payment Required",
  '403' = "Forbidden",
  '404' = "Not Found",
  '405' = "Method Not Allowed",
  '406' = "Not Acceptable",
  '407' = "Proxy Authentication Required",
  '408' = "Request Timeout",
  '409' = "Conflict",
  '410' = "Gone",
  '411' = "Length Required",
  '412' = "Precondition Failed",
  '413' = "Content Too Large",
  '414' = "URI Too Long",
  '415' = "Unsupported Media Type",
  '416' = "Range Not Satisfiable",
  '417' = "Expectation Failed",
  '418' = "I'm a teapot",
  '421' = "Misdirected Request",
  '422' = "Unprocessable Content",
  '423' = "Locked",
  '424' = "Failed Dependency",
  '425' = "Too Early",
  '426' = "Upgrade Required",
  '428' = "Precondition Required",
  '429' = "Too Many Requests",
  '431' = "Request Header Fields Too Large",
  '451' = "Unavailable For Legal Reasons",
  '500' = "Internal Server Error",
  '501' = "Not Implemented",
  '502' = "Bad Gateway",
  '503' = "Service Unavailable",
  '504' = "Gateway Timeout",
  '505' = "HTTP Version Not Supported",
  '506' = "Variant Also Negotiates",
  '507' = "Insufficient Storage",
  '508' = "Loop Detected",
  '510' = "Not Extended",
  '511' = "Network Authentication Required"
)
