

#______________________________________________________________________________
#' Generate a plot for the active project
#' @return list(image_url, r_code, stats_df, BIOM (optional), ...)
#' @noRd
api_plot <- function (
    REQ, plot_fn, plot_args, depth,
    save_args = list(), subset_args = list(), attrs = FALSE) {

  # `plot_fn` is one of the names listed in the route table, so it is safe
  # to look up in rbiom. The contents of `plot_args`, `save_args` and
  # `subset_args` are checked below (and by the step 6 schema).
  plot_args   <- as.list(plot_args)
  save_args   <- as.list(save_args)
  subset_args <- as.list(subset_args)

  resp <- list()
  
  # rare_multiplot can change depth.
  # Or after an aborted call to api_rarefy().
  if (rarefy_if_needed(REQ, depth)) {
    resume_session(REQ)
    resp %<>% c(list(BIOM = get_biom_data(REQ)))
  }
  
  draft_id    <- REQ[['SESSION']][['draft_id']]
  draft_key   <- REQ[['SESSION']][['draft_key']]
  full_bf_id  <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id  <- REQ[['SESSION']][['rare_bf_id']]
  server_temp <- REQ[['SESSION']][['server_temp']]
  client_temp <- REQ[['SESSION']][['client_temp']]
  
  
  
  plot_fun <- getFromNamespace(plot_fn, ns = "rbiom")
  
  
  #________________________________________________________
  # Numbers are integers by default; change to numeric.
  #________________________________________________________
  for (i in seq_along(plot_args))
    if (is.integer(plot_args[[i]]))
      plot_args[[i]] %<>% as.numeric()
  
  
  #________________________________________________________
  # JSON passes named c() as a list(). Change back to c().
  #________________________________________________________
  for (i in c('color.by', 'shape.by', 'pattern.by'))
    if (hasName(plot_args, i))
      for (j in seq_along(plot_args[[i]]))
        if (is.list(plot_args[[i]][[j]][['values']]))
          plot_args[[i]][[j]][['values']] %<>% unlist()
  
  
  #________________________________________________________
  # Simplify *.by args.
  #________________________________________________________
  for (i in grep("\\.by$", names(plot_args)))
    for (j in seq_along(plot_args[[i]])) {
      val <- plot_args[[i]][[j]]
      if (is.list(val) && length(val) == 1)
        if (hasName(val, 'values') || hasName(val, 'range'))
          plot_args[[i]][[j]] <- val[[1]]
    }
  
  
  #________________________________________________________
  # Sanitize user-provided arguments for ggsave()
  #________________________________________________________
  
  save_params <- setdiff(formalArgs(ggsave), c("bg", "limitsize", "..."))
  save_args   <- save_args[intersect(names(save_args), save_params)]
  
  save_args[['scale']]  <- ifelse(is.null(save_args[['scale']]),  1,   as.numeric(save_args[['scale']]))
  save_args[['width']]  <- ifelse(is.null(save_args[['width']]),  400, as.numeric(save_args[['width']]))
  save_args[['height']] <- ifelse(is.null(save_args[['height']]), 300, as.numeric(save_args[['height']]))
  save_args[['dpi']]    <- ifelse(is.null(save_args[['dpi']]),    300, as.numeric(save_args[['dpi']]))
  if (is.null(save_args[['device']])) save_args[['device']] <- "png"
  if (is.null(save_args[['units']]))  save_args[['units']]  <- "px"
  
  if (!is_one_of(save_args[['device']], c("eps", "ps", "tex", "pdf", "jpeg", "tiff", "png", "bmp", "svg", "wmf")))
    stop_user("Unknown image format.")

  if (!is_one_of(save_args[['units']], c("in", "cm", "mm", "px")))
    stop_user("Unknown image size units.")

  for (i in seq_len(length(save_args)))
    if (length(save_args[[i]]) != 1 || is.na(save_args[[i]]))
      stop_user("Invalid image setting '", names(save_args)[[i]], "'.")
  
  
  
  #________________________________________________________
  # Write to <client_temp>/plot_<random>.<suffix>
  #________________________________________________________
  outfile <- plot_filename(server_temp, save_args[['device']])
  save_args[['filename']] <- outfile
  save_args[['path']]     <- server_temp
  
  
  
  #________________________________________________________
  # Retrieve the BIOM object for the active project
  #________________________________________________________
  plot_args[['biom']] <- local({
    biom_file_id <- ifelse(plot_fn == "rare_multiplot", full_bf_id, rare_bf_id)
    get_biom(REQ, biom_file_id)
  })
  
  
  
  #________________________________________________________
  # Apply subset_args for categorical fields.
  #________________________________________________________
  if (is.list(subset_args[['cat']]))
    plot_args[['biom']] <- local({
      
      biom <- plot_args[['biom']]
      for (i in seq_along(subset_args[['cat']])) {
        
        col_name   <- names(subset_args[['cat']])[[i]]
        col_values <- subset_args[['cat']][[i]]
        
        if (!is_one_of(col_name, biom$fields))
          stop_user("Unknown metadata field in subset.")

        if (!is.character(col_values) || length(col_values) == 0 || !is.null(names(col_values)))
          stop_user("Invalid subset values for '", col_name, "'.")
        
        x <- biom$metadata
        x[[col_name]] %<>% factor(levels = col_values)
        x <- x[!is.na(x[[col_name]]),,drop=FALSE]
        biom$metadata <- x
      }
      
      return (biom)
    })
  
  
  
  #________________________________________________________
  # Apply subset_args for numeric fields.
  #________________________________________________________
  if (is.list(subset_args[['num']]))
    plot_args[['biom']] <- local({
      
      biom <- plot_args[['biom']]
      for (i in seq_along(subset_args[['num']])) {
        
        col_name  <- names(subset_args[['num']])[[i]]
        col_range <- subset_args[['num']][[i]]
        
        if (!is_one_of(col_name, biom$fields))
          stop_user("Unknown metadata field in subset.")

        if (!is.numeric(col_range) || length(col_range) != 2 || anyNA(col_range) || !is.null(names(col_range)))
          stop_user("Invalid subset range for '", col_name, "'.")
        
        lo <- col_range[[1]]
        hi <- col_range[[2]]
        
        x <- biom$metadata
        vals <- x[[col_name]]
        vals[which(vals < lo | vals > hi)] <- NA
        x <- x[!is.na(vals),,drop=FALSE]
        biom$metadata <- x
      }
      
      return (biom)
    })
  
  
  #________________________________________________________
  # Generate the plot
  #________________________________________________________
  p <- with_user_errors("The plot could not be made.", do.call(plot_fun, plot_args))
  
  
  #________________________________________________________
  # Save the figure in the requested format
  #________________________________________________________
  save_args[['plot']]      <- p
  save_args[['limitsize']] <- FALSE
  
  if (capabilities("cairo") && save_args[['device']] %in% c("png", "jpeg", "tiff", "bmp"))
    save_args[['type']] <- "cairo" # better anti-aliasing
  
  do.call(ggsave, save_args)
  
  
  #________________________________________________________
  # Always return the URL to the generated figure
  #________________________________________________________
  resp %<>% c(list(
    'image_url' = unbox(paste0(client_temp, "/", outfile)),
    'width'     = unbox(save_args[['width']]),
    'height'    = unbox(save_args[['height']]),
    'scale'     = unbox(save_args[['scale']]),
    'dpi'       = unbox(save_args[['dpi']]),
    'device'    = unbox(save_args[['device']]),
    'units'     = unbox(save_args[['units']]) ))
  
  
  #________________________________________________________
  # Optionally return stats, code, etc
  #________________________________________________________
  if (isTRUE(attrs)) {
    
    resp[['attrs']] <- unbox(TRUE)
    
    if (!is.null(attr(p, 'stats', exact = TRUE))) {
      resp[['stats_table']] <- attr(p, 'stats')
      stats_cols <- colnames(resp[['stats_table']])
      stats_cols <- sub("^\\.", "", stats_cols)
      stats_cols <- gsub(".", "_", stats_cols, fixed = TRUE)
      colnames(resp[['stats_table']]) <- stats_cols
    }
    
    sample_set <- ifelse(plot_fn == "rare_multiplot", "full", "rare")
    
    resp[['code']] <- list(
      
      'file'  = unbox(sprintf("%s/%s.json", draft_key, sample_set)),
      
      'rbiom' = unbox(p %>% attr('cmd',  TRUE)),
      
      'ggplot2' = unbox(paste0(
        sprintf("p    <- %s\n\n",     p %>% attr('cmd',  TRUE)),
        sprintf("data <- p$data\n%s", p %>% attr('code', TRUE)) )) )
    
    if (!is.null(attr(p, 'stats', TRUE)))
      resp[['code']][['stats']] = unbox(p %>% attr('stats', TRUE) %>% attr('code', TRUE))
    
    resp[['stats_title']] <- p %>% attr('stats', TRUE) %>% attr('tbl_sum', TRUE)
    if (!is.null(resp[['stats_title']])) resp[['stats_title']] %<>% lapply(unbox)
    
  } else {
    resp[['attrs']] <- unbox(FALSE)
  }
  
  return (resp)
}



#______________________________________________________________________________
#' A file name for a new figure that no other request is using.
#' 
#' The file is created (empty) to reserve the name, so two requests in the
#' same session can never be handed the same one.
#' @return a file name (not a path) inside `dir`.
#' @noRd
plot_filename <- function (dir, device) {
  for (i in 1:10) {
    filename <- sprintf("plot_%s.%s", random_string(10), device)
    if (file.create(file.path(dir, filename), showWarnings = FALSE))
      return (filename)
  }
  stop("Unable to create a file for the figure.")
}
