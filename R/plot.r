

#______________________________________________________________________________
#' Generate a plot for the active project
#' @return list(image_url, r_code, stats_df, [BIOM], ...)
api_plot <- function (
    REQ, plot_fn, plot_args, depth, 
    save_args = list(), subset_args = list(), attrs = FALSE) {
  
  #________________________________________________________
  # Sanitize user-provided plotting function name
  #________________________________________________________
  stopifnot(is_one_of(plot_fn, c(
    "adiv_boxplot", "adiv_corrplot", "bdiv_boxplot", "bdiv_heatmap", 
    "bdiv_ord_plot", "rare_multiplot", "taxa_stacked", "taxa_boxplot", 
    "taxa_corrplot", "taxa_heatmap" )))


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
  
  stopifnot(is_one_of(save_args[['device']], c("eps", "ps", "tex", "pdf", "jpeg", "tiff", "png", "bmp", "svg", "wmf")))
  stopifnot(is_one_of(save_args[['units']], c("in", "cm", "mm", "px")))
  
  for (i in seq_len(length(save_args)))
    stopifnot(length(save_args[[i]]) == 1)
  
  
  
  #________________________________________________________
  # Write to <client_temp>/<seconds modulo>.<suffix>
  #________________________________________________________
  outfile <- sprintf("%04i.%s", as.integer(Sys.time()) %% 10000, save_args[['device']])
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
        
        stopifnot(is_one_of(col_name, biom$fields))
        stopifnot(is.character(col_values))
        stopifnot(length(col_values) > 0)
        stopifnot(is.null(names(col_values)))
        
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
        
        stopifnot(is_one_of(col_name, biom$fields))
        stopifnot(is.numeric(col_range))
        stopifnot(length(col_range) == 2)
        stopifnot(!anyNA(col_range))
        stopifnot(is.null(names(col_range)))
        
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
  p <- do.call(plot_fun, plot_args)
  
  
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
      colnames(resp[['stats_table']]) %<>% gsub("^\\.", "", .)
      colnames(resp[['stats_table']]) %<>% gsub(".", "_", ., fixed = TRUE)
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


