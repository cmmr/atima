

#______________________________________________________________________________
#' Accept a new biom file from the user; switch to that project.
#' @return list(BIOM, jstree_node)
api_upload_biom <- function (REQ, biom_file) {
  
  DB          <- REQ[['DB']]
  user_id     <- REQ[['SESSION']][['user_id']]
  session_id  <- REQ[['SESSION']][['session_id']]
  server_temp <- REQ[['SESSION']][['server_temp']]
  
  
  #________________________________________________________
  # Import the new BIOM file, using filename for title.
  #________________________________________________________
  infile <- tempfile(tmpdir = server_temp)
  on.exit(unlink(infile), add = TRUE)
  writeBin(object = biom_file[['value']], con = infile)
  
  title <- basename(biom_file[['filename']])
  title <- sub("\\.(biom|txt|tab)\\.*(gz|bz2|)$", "", title)
  title <- substr(title, 0, 100)
  
  project_id <- add_project(REQ, infile, title = title)
  
  
  #________________________________________________________
  # Create and switch to a new draft for this project.
  #________________________________________________________
  draft_id <- create_draft(DB, project_id)
  db_update(
    DB       = DB, 
    table    = 'sessions', 
    id       = session_id, 
    err_code = "AUBiom1",
    draft_id = draft_id )
  
  resume_session(REQ)
  BIOM <- get_biom_data(REQ)
  
  
  #________________________________________________________
  # Create a new jstree_node.
  #________________________________________________________
  sql <- paste0(
    "SELECT * FROM permissions",
    " LEFT JOIN projects USING (project_id)",
    " WHERE user_id = ? AND project_id = ?" )
  row         <- db_query(DB, sql, "AUBiom2", list(user_id, project_id))
  jstree_node <- compile_jstree_node(DB, row)
  
  
  return (list(BIOM = BIOM, jstree_node = jstree_node))
}



#______________________________________________________________________________
#' Import a metadata csv, taxonomy csv, or newick tree file
#' @return list(BIOM)
api_upload_component <- function (REQ, component, component_file) {
  
  DB         <- REQ[['DB']]
  TEMP_DIR   <- REQ[['CONFIG']][['temp_dir']]
  draft_id   <- REQ[['SESSION']][['draft_id']]
  full_bf_id <- REQ[['SESSION']][['full_bf_id']]
  rare_bf_id <- REQ[['SESSION']][['rare_bf_id']]
  
  
  #________________________________________________________
  # Multipart uploads have raw-encoded values
  #________________________________________________________
  component      <- rawToChar(component[['value']])
  component_file <- component_file[['value']]
  
  stopifnot(is_one_of(component, c('metadata', 'taxonomy', 'tree')))
  stopifnot(is_raw(component_file))
  
  
  
  #________________________________________________________
  # Add the new component data to full_biom.
  #________________________________________________________
  full_biom <- get_biom(REQ, full_bf_id)
  
  infile <- tempfile(tmpdir = TEMP_DIR)
  on.exit(unlink(infile), add = TRUE)
  writeBin(object = component_file, con = infile)
  
  
  #________________________________________________________
  # Load the new metadata/taxonomy/tree into the rbiom obj.
  #________________________________________________________
  full_biom[[component]] <- infile
  
  
  
  #________________________________________________________
  # Re-rarefy to the previous depth.
  #________________________________________________________
  rare_biom <- get_biom(REQ, rare_bf_id)
  depth     <- rare_biom$depth
  rare_biom <- rarefy(full_biom, depth = depth)
  
  
  
  #________________________________________________________
  # Save the updated BIOMs to this draft.
  #________________________________________________________
  full_bf_id <- store_biom(REQ, full_biom)
  rare_bf_id <- store_biom(REQ, rare_biom)
  
  db_update(
    DB         = DB, 
    table      = "drafts", 
    id         = draft_id, 
    err_code   = "UComp1",
    full_bf_id = full_bf_id,
    rare_bf_id = rare_bf_id )
  
  
  resume_session(REQ)
  BIOM <- get_biom_data(REQ)
  
  return (list(BIOM = BIOM))
}



#______________________________________________________________________________
#' api/export/{original|metadata|taxonomy|phylogeny}
#' api/export/biom/{rare|full}/{hdf5|json|tab}
#' api/export/alpha/{rare|full}
#' api/export/beta/<method>/{w|u}    (implies rarefied)
#' api/export/taxa/<rank>/{rare|full}
#' @return list(download_url)
api_export <- function (REQ) {
  
  DB          <- REQ[['DB']]
  PATH        <- REQ[['PATH']]
  project_id  <- REQ[['SESSION']][['project_id']]
  client_temp <- REQ[['SESSION']][['client_temp']]
  server_temp <- REQ[['SESSION']][['server_temp']]
  
  
  
  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "AExpo1", list(project_id), req1 = TRUE)
  
  
  #________________________________________________________
  # Split path into words and drop /api/export/ prefix.
  #________________________________________________________
  p <- strsplit(PATH, '/', fixed = TRUE)[[1]]
  p <- p[nchar(p) > 0][-c(1:2)]
  
  
  #________________________________________________________
  # Use the full biom unless otherwise specified in path.
  #________________________________________________________
  biom <- ifelse("rare" %in% p, "rare", "full")
  if (identical(p[[1]], "beta"))     biom <- "rare"
  if (identical(p[[1]], "original")) biom <- "orig"
  
  biom_file_id <- project[[paste0(biom, '_bf_id')]]
  biom         <- get_biom(REQ, biom_file_id)
  
  
  
  #________________________________________________________
  # Convert the request path to a filename for saving to.
  #________________________________________________________
  filepath <- local({
    
    file_ext <- ifelse(identical(p[[1]], "biom"), p[[3]], "csv")
    if (identical(p[[1]], "original")) file_ext <- "biom"
    if (identical(p[[1]], "tree"))     file_ext <- "tre"
    if (!is_one_of(file_ext, c("csv", "biom", "tre", "tab", "json", "hdf5")))
      stop("Invalid file extension:", file_ext)
    
    drop_terms <- c("api", "export", "biom", "beta", "taxa", "hdf5", "json", "tab")
    key_terms  <- setdiff(p, drop_terms)
    bad_terms  <- grep("^[a-zA-Z0-9\\-]{1,20}$", key_terms, value = TRUE, invert = TRUE)
    if (length(bad_terms) > 0)
      stop("Invalid export term(s): ", paste(collapse = ", ", bad_terms))
    
    filename <- paste(collapse = "_", c(key_terms, biom_file_id))
    
    return (sprintf("%i/%s.%s", biom_file_id, filename, file_ext))
  })
  
  client_uri <- paste0(client_temp, "/", filepath)
  server_uri <- paste0(server_temp, "/", filepath)
  dir.create(dirname(server_uri), recursive = TRUE)
  
  
  
  #________________________________________________________
  # Check if the file already exists.
  #________________________________________________________
  if (file.exists(server_uri)) {
    Sys.setFileTime(server_uri, Sys.time())
    return (list('download_url' = unbox(client_uri)))
  }
  
  
  
  #________________________________________________________
  # Write requested object to the output file.
  #________________________________________________________
  if (identical(p[[1]], "metadata")) {
    write.csv(biom$metadata, server_uri, row.names = FALSE)
    
    
  } else if (identical(p[[1]], "taxonomy")) {
    write.csv(biom$taxonomy, server_uri, row.names = FALSE)
    
    
  } else if (identical(p[[1]], "tree")) {
    write_tree(biom$tree, server_uri)
    
    
  } else if (identical(p[[1]], 'original')) {
    file.copy(get_biom_file(REQ, biom_file_id), server_uri)
    
    
  } else if (identical(p[[1]], 'biom')) {
    
    biom$id      <- project[['title']]
    biom$comment <- paste0(collapse = '\n', pandoc_convert(
      text = project[['description']], from = 'html', to = 'markdown' ))
    
    write_biom(biom, server_uri, format = p[[3]])
    
    
  } else if (identical(p[[1]], 'alpha')) {
    adiv <- adiv_matrix(biom)
    write.csv(adiv, server_uri)
    
    
  } else if (identical(p[[1]], 'beta')) {
    method   <- if.null(p[[2]], "bray")
    bdiv     <- bdiv_distmat(biom, method)
    write.csv(as.matrix(bdiv), server_uri)
    
    
  } else if (identical(p[[1]], 'taxa')) {
    rank <- if.null(p[[2]], "otu")
    taxa <- taxa_matrix(biom, rank)
    write.csv(taxa, server_uri)
    
    
  } else {
    stop('Invalid export request.')
  }
  
  
  return (list('download_url' = unbox(client_uri)))
}




#______________________________________________________________________________
#' Save BIOM objects as BIOM files in atima's data directory.
#' @return biom_file_id
store_biom <- function (REQ, biom) {
  
  TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]
  
  biom_file_id <- tryCatch(
    error = function (e) stop("StoreBiom: ", e),
    expr  = local({
      tfile <- tempfile(tmpdir = TEMP_DIR, fileext = ".json.bz2")
      on.exit(file.remove(tfile))
      write_biom(biom, file = tfile, format = "json")
      store_file(REQ, tfile)
    }))
  
  
  # Likely to be re-fetched soon.
  with_cache(
    REQ  = REQ,
    key  = paste0(biom_file_id, "_get_biom"),
    expr = local({ return (biom) }))
  
  
  return (biom_file_id)
}




#______________________________________________________________________________
#' Renames and saves a file to atima's data directory.
#' @return biom_file_id
store_file <- function (REQ, file) {
  
  DB        <- REQ[['DB']]
  FILES_DIR <- file.path(REQ[['CONFIG']][['data_dir']], 'files')
  
  
  tryCatch(
    
    error = function (e) stop("StoreFile: ", e),
    expr  = local({
      
      #________________________________________________________
      # See if we already have a copy of this biom file.
      #________________________________________________________
      hash <- hash_file(file)
      sql  <- "SELECT * FROM biom_files WHERE hash = ?"
      res  <- db_query(DB, sql, "SFile1", list(hash), simplify = FALSE)
      
      if (nrow(res) > 0) {
        curr <- read_file_raw(file)
        for (i in seq_len(nrow(res)))
          if (identical(curr, read_file_raw(paste0(FILES_DIR, "/", res[i, 'file']))))
            return (res[i, 'biom_file_id'])
      }
      
      
      #________________________________________________________
      # Copy into the data directory with a random name.
      #________________________________________________________
      biom_file <- paste0(FILES_DIR, "/", random_string(10), ".biom")
      for (i in 1:10) {
        if (!file.exists(biom_file)) break
        if (i == 10) stop("Too many collisions. SFile2")
        biom_file <- paste0(FILES_DIR, "/", random_string(10), ".biom")
      }
      file.copy(from = file, to = biom_file)
      
      
      #________________________________________________________
      # Add to the database table and get an auto-generated ID.
      #________________________________________________________
      sql          <- "INSERT INTO biom_files (file, hash) VALUES (?, ?)"
      biom_file_id <- db_query(DB, sql, "SFile3", list(basename(biom_file), hash))
      
      
      return (biom_file_id)
    }))
}



#______________________________________________________________________________
#' Read biom files from atima's data directory.
#' @return a BIOM object
#' @examples
#' get_biom(REQ, biom_file_id = 100)
get_biom <- function (REQ, biom_file_id) {
  
  biom <- with_cache(
    REQ  = REQ,
    key  = paste0(biom_file_id, "_get_biom"),
    expr  = local({
      file <- get_biom_file(REQ, biom_file_id)
      biom <- as_rbiom(biom = file)
      return (biom)
    }))
  
  return (biom)
}



#______________________________________________________________________________
#' Values for front-end's `BIOM` variable.
#' 
#' @return list()
get_biom_data <- function (REQ) {
  
  DB            <- REQ[['DB']]
  project_id    <- REQ[['SESSION']][['project_id']]
  rare_bf_id    <- REQ[['SESSION']][['rare_bf_id']]
  full_bf_id    <- REQ[['SESSION']][['full_bf_id']]
  permission_id <- REQ[['SESSION']][['permission_id']]
  
  
  BIOM <- list(
    title       = unbox(REQ[['SESSION']][['title']]),
    description = unbox(REQ[['SESSION']][['description']]),
    access_key  = unbox(REQ[['SESSION']][['access_key']]),
    project_key = unbox(REQ[['SESSION']][['project_key']]),
    is_saved    = unbox(REQ[['SESSION']][['is_saved']]),
    is_editor   = unbox(REQ[['SESSION']][['is_editor']]),
    is_public   = unbox(REQ[['SESSION']][['is_public']]) )
  
  
  #________________________________________________________
  # jsTree node ID = "P" + permission id.
  #________________________________________________________
  if (is.na(permission_id)) {
    sql <- "SELECT permission_id FROM permissions WHERE project_id = ? AND user_id = 0"
    permission_id <- db_query(DB, sql, "GBData1", list(project_id), req1 = TRUE)
  }
  BIOM[['node_id']] <- unbox(paste0("P", permission_id))
  
  
  #________________________________________________________
  # Cache all the information derived from the biom object.
  #________________________________________________________
  BIOM %<>% c(
    with_cache(
      REQ  = REQ,
      key  = paste0(rare_bf_id, "_biom_data"),
      expr = local({
        
        
        #________________________________________________________
        # Compute the rare_biom's client_data values.
        #________________________________________________________
        D <- list()
        
        full_biom   <- get_biom(REQ, full_bf_id)
        rare_biom   <- get_biom(REQ, rare_bf_id)
        metadata    <- rare_biom$metadata
        sample_sums <- sample_sums(full_biom)
        
        
        #________________________________________________________
        # Phylogenetic tree.
        #________________________________________________________
        has_tree    <- !is.null(rare_biom$tree)
        D[['tree']] <- unbox(has_tree)
        
        
        #________________________________________________________
        # Current and possible rarefaction depths.
        #________________________________________________________
        D[['depth']]         <- unbox(rare_biom$depth)
        D[['depth_options']] <- sort(unique(sample_sums))
        
        
        #________________________________________________________
        # Available metrics.
        #________________________________________________________
        phylo <- if (has_tree) NULL else FALSE
        D[['adiv_options']]  <- list_metrics('alpha', 'name', phylo = phylo)
        D[['bdiv_options']]  <- list_metrics('beta',  'name', phylo = phylo)
        D[['clust_options']] <- c('average', 'ward', 'mcquitty', 'single', 'median', 'complete', 'centroid')
        D[['dist_options']]  <- c('euclidean', 'maximum', 'manhattan', 'canberra', 'binary', 'minkowski')
        D[['ord_options']]   <- c('PCoA', 'tSNE', 'NMDS', 'UMAP')
        
        
        #________________________________________________________
        # taxa = list(Phylum = c(...), OTU = c(...), ...)
        #________________________________________________________
        D[['rank_options']] <- rare_biom$ranks
        D[['taxa_options']] <- list()
        for (i in rare_biom$ranks)
          D[['taxa_options']][[i]] <- names(taxa_means(rare_biom, i))
        
        
        #________________________________________________________
        # Metadata field names, types, and options/ranges.
        #________________________________________________________
        D[['cols']]    <- colnames(metadata)
        D[['col_types']]   <- list()
        D[['col_options']] <- list()
        
        for (col_name in colnames(metadata)) {
          
          col_vals <- metadata[[col_name]]
          
          if (is.character(col_vals)) {
            
            D[['cols_cat']] %<>% c(col_name)
            D[['col_types']][[col_name]]   <- unbox("cat")
            D[['col_options']][[col_name]] <- sort(unique(col_vals))
            
          } else if (is.factor(col_vals)) {
            
            D[['cols_cat']] %<>% c(col_name)
            D[['col_types']][[col_name]]   <- unbox("cat")
            D[['col_options']][[col_name]] <- levels(col_vals)
            
          } else if (is.numeric(col_vals)) {
            
            D[['cols_num']] %<>% c(col_name)
            D[['col_types']][[col_name]]   <- unbox("num")
            D[['col_options']][[col_name]] <- list(
              min = unbox(min(col_vals, na.rm = TRUE)),
              max = unbox(max(col_vals, na.rm = TRUE)) )
            
          }
        }
        
        D[['cols_num']] %<>% if.null(list())
        
        return (D)
      })))
  
  
  return (BIOM)
}


#______________________________________________________________________________
#' Get the file path for a biom file stored in atima's data directory.
#' @return a string
#' @examples
#' get_biom_file(REQ, biom_file_id = 100)
get_biom_file <- function (REQ, biom_file_id) {
  
  DB        <- REQ[['DB']]
  FILES_DIR <- file.path(REQ[['CONFIG']][['data_dir']], 'files')
  
  file <- with_cache(
    REQ  = REQ,
    key  = paste0(biom_file_id, "_get_biom_file"),
    expr  = local({
      sql  <- "SELECT file FROM biom_files WHERE biom_file_id = ?"
      file <- db_query(DB, sql, "GBFile1", list(biom_file_id), req1 = TRUE)
      file <- paste0(FILES_DIR, "/", file)
      return (file)
    }))
  
  return (file)
}



#______________________________________________________________________________
#' Run (and cache) an rbiom function on a given biom_file_id.
#' @return The rbiom function's output.
#' @examples
#' get_biom_component(REQ, biom_file_id = 100, rbiom_fn = "metadata")
get_biom_component <- function (REQ, biom_file_id, rbiom_fn) {
  
  stopifnot(is_one_of(rbiom_fn, c(
    "comment", "counts", "date", "depth", "fields", "id", "metadata", 
    "n_fields", "n_otus", "n_ranks", "n_samples", "otus", "ranks", 
    "samples", "sequences", "taxonomy", "tree" )))
  
  with_cache(
    REQ  = REQ,
    key  = paste0(biom_file_id, "_", rbiom_fn),
    expr = local({
      get_biom(REQ, biom_file_id)[[rbiom_fn]]
    }))
}



#______________________________________________________________________________
#' The entire contents of a file as a raw vector.
#' @return a raw vector; `raw(0)` if the file does not exist.
read_file_raw <- function (file) {
  if (!file.exists(file)) return (raw(0))
  readBin(file, what = 'raw', n = file.size(file))
}



#______________________________________________________________________________
#' General purpose cache localized to a given directory.
with_cache <- function (REQ, key, expr) {
  
  CACHE_DIR  <- file.path(REQ[['CONFIG']][['data_dir']], 'cache')
  CACHE_SIZE <- REQ[['CONFIG']][['cache_size']]
  
  cache_file <- sprintf("%s/%s.rds", CACHE_DIR, key)
  
  
  #________________________________________________________
  # Already exists in cache.
  #________________________________________________________
  if (Sys.setFileTime(cache_file, Sys.time()))
    return (readRDS(cache_file))
  
  
  #________________________________________________________
  # Don't cache objects larger than cache_size.
  #________________________________________________________
  value      <- eval.parent(expr)
  value_size <- as.integer(object.size(value))
  if (value_size >= CACHE_SIZE)
    return (value)
  
  
  #________________________________________________________
  # Delete old files to stay under the maximum.
  #________________________________________________________
  files <- list.files(CACHE_DIR, full.names = TRUE, recursive = TRUE)
  files <- file.info(files)[,c('size', 'mtime'),drop=FALSE]
  files <- files[rev(order(files[['mtime']])),,drop=FALSE]
  files <- files[cumsum(files[['size']]) + value_size > CACHE_SIZE,,drop=FALSE]
  if (nrow(files) > 0) file.remove(rownames(files))
  
  
  saveRDS(value, file = cache_file)
  
  return (value)
}






