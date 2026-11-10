
call_stack <- function () {
  calls <- sys.calls()
  calls <- head(calls, length(calls) - 8)
  calls <- head(calls, which(startsWith(calls, "call_stack"))[[1]] - 2)
  paste(collapse = "\n", c("Call Stack:", calls))
}


#______________________________________________________________________________
#' An HTML block for error_modal with error details .
error_details <- function (err_obj, err_code = NULL, ...) {
  
  
  #________________________________________________________
  # The primary text to display in the error modal
  #________________________________________________________
  err_message <- as.character(err_obj)
  
  
  #________________________________________________________
  # Custom error detail(s) in `...`
  #________________________________________________________
  details <- list(...)
  
  if (length(details) > 0) {
    if (is.null(names(details)))
      names(details) <- rep_len("More Details", length(details))
    if (any(names(details) == ""))
      names(details)[which(names(details) == "")] <- "More Details"
  }
  
  
  #________________________________________________________
  # Which functions were called to lead to this error?
  #________________________________________________________
  calls <- rev(as.character(sys.calls()))
  calls <- rev(head(calls, min(5, which(startsWith(calls, "api_")))[[1]]))
  calls <- head(calls, which(startsWith(calls, "error_details"))[[1]] - 2)
  details[['Call Stack']] <- paste(collapse = "\n", calls)
  
  
  
  #________________________________________________________
  # Code dumps to display in fieldsets.
  #________________________________________________________
  dumps <- lapply(seq_along(details), function (i) {
    
    title <- names(details)[[i]]
    code  <- details[[i]]
    lang  <- unname(c("SQL" = "sql", "Call Stack" = "r")[title])
    
    if (nchar(code) > 400)
      code <- paste0(substr(code, 1, 400), "...")
    
    list(
      title = unbox(title),
      code  = unbox(code),
      lang  = unbox(lang)
    )
  })
  
  return (structure(
    list(
      message = toJSON(list(
        message = unbox(err_message),
        errcode = unbox(err_code),
        dumps   = dumps )),
      call    = NULL
    ),
    class = c("error", "condition")
  ))
}


