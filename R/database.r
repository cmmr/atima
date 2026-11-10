


#______________________________________________________________________________
#' Connect to the SQLite database file.
#' @noRd
db_connect <- function (DATA_DIR) {
  
  DB <- try(silent = TRUE, dbConnect(
    drv    = SQLite(), 
    dbname = file.path(DATA_DIR, "sqlite.db") ))
  
  if (!inherits(DB, 'SQLiteConnection'))
    stop('Unable to connect to SQLite. (DConn1)')
  
  return (DB)
}


#______________________________________________________________________________
#' Close/Disconnect a database connection.
#' @noRd
db_close <- function (DB) {
  stopifnot(is(DB, "SQLiteConnection"))
  try(silent = TRUE, dbDisconnect(DB))
}


#______________________________________________________________________________
#' Initialize the database if it's currently empty.
#' @noRd
db_init <- function (config) {
  
  data_dir <- config[['data_dir']]
  
  db <- db_connect(data_dir)
  if (isTRUE(length(dbListTables(db)) == 0)) {
    
    for (subdir in file.path(data_dir, c('files', 'cache'))) {
      if (dir.exists(subdir))
        unlink(subdir, recursive = TRUE, expand = FALSE)
      dir.create(subdir, recursive = TRUE)
    }
    
    init_db_structure(db)
    init_db_content(db, config)
  }
  db_close(db)
  
}


#______________________________________________________________________________
#' Wrapper around DBI's dbGetQuery and dbExecute.
#' 
#' @param DB  DBI connection object.
#' @param sql  A single SQL statement to run.
#' @param err_code  A unique error code to emit if an error occurs.
#' @param params  A list of values for the statement's \code{?} placeholders.
#' @param simplify  Return single values or named arrays instead of data frames 
#'        whenever possible. (Default: TRUE)
#' @param req1  Generate an error unless the SELECT query matches exactly one row.
#'
#' @return A data.frame of the SELECT result, potentially simplified if 
#'         \code{simplify=TRUE}. For an INSERT, the new rowid. For SQL statements
#'         other than SELECT/INSERT, the value returned by \code{dbExecute()}.
#' @noRd
db_query <- function (DB, sql, err_code, params = NULL, simplify = TRUE, req1 = FALSE) {
  
  tryCatch(
    
    error = function (e)
      stop(
        call. = FALSE,
        "In db_query (", err_code,"): \n", e, "\n", sql, "\n\n", 
        "Params = ", toJSON(params, auto_unbox = TRUE) ), 
    
    expr = local({
      
      
      stopifnot(is(DB, "SQLiteConnection"))
      stopifnot(is_scalar_character(sql))
      stopifnot(is_scalar_character(err_code))
      
      
      sql  <- trimws(gsub("[\n\r\t\ ]+", " ", sql))
      verb <- toupper(strsplit(substr(sql, 1, 10), ' ', fixed = TRUE)[[1]][[1]])
      if (!is_one_of(verb, c("SELECT", "INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "ROLLBACK")))
        stop("Invalid SQL verb: '", verb, "'.")
        
      
      #________________________________________________________
      # Run the query/statement
      #________________________________________________________
      result <- do.call(
          what = if (verb == "SELECT") dbGetQuery else dbExecute, 
          args = list(conn = DB, statement = sql, params = params) )
        
        
        
      #________________________________________________________
      # For INSERT statements, the result is the new row_id
      #________________________________________________________
      if (verb == "INSERT")
        result <- tryCatch(
          error = function (e) stop("LAST_INSERT_ROWID(): ", e, call. = FALSE),
          expr  = dbGetQuery(DB, "SELECT LAST_INSERT_ROWID()")[1,1]  )
      
      
      
      #________________________________________________________
      # Only concerned with SELECT output from here on down.
      #________________________________________________________
      if (verb != "SELECT") return (result)
      
      
      
      #________________________________________________________
      # Enforce req1 - Need exactly one result row.
      #________________________________________________________
      if (isTRUE(req1)) {
        if (nrow(result) == 0) stop("req1 - No matching rows found.", call. = FALSE)
        if (nrow(result) >= 2) stop("req1 - Too many results found.", call. = FALSE)
      }
      
      
      
      #________________________________________________________
      # Use column names to convert to boolean and POSIXct.
      #________________________________________________________
      for (k in colnames(result)) {
        if        (startsWith(k, "is_"))  { result[[k]] <- as.logical(result[[k]])
        } else if (startsWith(k, "has_")) { result[[k]] <- as.logical(result[[k]])
        } else if (endsWith(  k, "_utc")) { result[[k]] <- as.POSIXct(result[[k]], tz = "UTC") }
      }
      
      
      
      #________________________________________________________
      # Try to simplify the data.frame.
      #________________________________________________________
      if (isTRUE(simplify) && is.data.frame(result)) {
        if (nrow(result) == 0) return (NULL)
        if (ncol(result) == 1) return (result[[1]])
        if (nrow(result) == 1) return (as.list(result))
      }
      
      return (result)
      
    }))
}


#______________________________________________________________________________
#' Create and run an INSERT statement.
#' @noRd
db_insert <- function (DB, table, err_code, ..., defaults = list()) {
  
  
  # Allow unnamed arguments, e.g. db_insert(DB, 'permissions', user_id, project_id)
  values <- named_dots(...)
  stopifnot(length(values) > 0)
  
  
  # Add in any relevant defaults
  stopifnot(is.list(defaults))
  values %<>% c(defaults[setdiff(names(defaults), names(values))])
  
  
  # Prevent SQL injection through table/column names.
  stopifnot(is_scalar_character(table))
  stopifnot(all(grepl("^[a-zA-Z_]+$", c(table, names(values)))))
  
  
  # Values with attribute sql=TRUE don't get bound as variables.
  values <- lapply(values, function (v) {
    if (is.null(v) || is.na(v)) structure("NULL", sql = TRUE) else v })
  static <- sapply(values, function (x) { isTRUE(attr(x, 'sql', exact = TRUE)) })
  params <- if (all(static)) NULL else unname(values[!static])
  sql    <- sprintf(
    fmt = "INSERT INTO %s (%s) VALUES (%s)",
    table,
    paste(collapse=", ", names(values)),
    paste(collapse=", ", ifelse(static, values, "?")) )
  
  return (db_query(DB, sql, err_code, params))
}


#______________________________________________________________________________
#' Create and run an UPDATE statement.
#' The `id` is the primary key for the row to be updated.
#' @noRd
db_update <- function (DB, table, id, err_code, ...) {
  
  
  # Allow unnamed arguments, e.g. db_update(DB, 'projects', project_id, title)
  values <- named_dots(...)
  stopifnot(length(values) > 0)
  
  
  # Prevent SQL injection through table/column names.
  stopifnot(is_scalar_integerish(id))
  stopifnot(is_scalar_character(table))
  stopifnot(all(grepl("^[a-zA-Z_]+$", c(table, names(values)))))
  
  
  # Confirm we'll be changing exactly one row.
  db_row_exists(DB, table, id)
  
  
  # Values with attribute sql=TRUE don't get bound as variables.
  values <- lapply(values, function (v) {
    if (is.null(v) || is.na(v)) structure("NULL", sql = TRUE) else v })
  static <- sapply(values, function (x) { isTRUE(attr(x, 'sql', exact = TRUE)) })
  params <- if (all(static)) list(id) else c(unname(values[!static]), list(id))
  values <- paste(names(values), ifelse(static, paste("=", values), "= ?"))
  values <- paste(collapse=", ", values)
  sql    <- sprintf("UPDATE %s SET %s WHERE ROWID = ?", table, values)
  
  return (db_query(DB, sql, err_code, params))
}



#______________________________________________________________________________
#' Check that a primary key exists in a table.
#' @noRd
db_row_exists <- function (DB, table, id, assert=TRUE) {
  
  stopifnot(is_scalar_integerish(id))
  stopifnot(is_scalar_character(table))
  stopifnot(isTRUE(grepl("^[a-z_]+$", table)))
  
  sql <- "SELECT COUNT(*) FROM %s WHERE ROWID = ?"
  sql <- sprintf(sql, table)
  n   <- db_query(DB, sql, "DRExis1", list(id))
  
  if (identical(n, 0L) && isTRUE(assert)) {
    msg <- "RowID %i does not exist in table %s. Please reload the page."
    stop(sprintf(msg, id, table))
  }
  
  return (identical(n, 1L))
}


#______________________________________________________________________________
#' Initialize the SQL database tables.
#' @noRd
init_db_structure <- function (DB) {
  
  stopifnot(is(DB, "SQLiteConnection"))
  cat(file = stdout(), "Initializing SQLite database.\n")
  
  
  statements <- gsub("[\n\r\t\ ]+", " ", c(
    
    "CREATE TABLE IF NOT EXISTS users (
      user_id      INTEGER PRIMARY KEY,
      full_name    TEXT    NOT NULL DEFAULT 'Guest',
      affiliation  TEXT        NULL DEFAULT NULL,
      email        TEXT        NULL DEFAULT NULL,
      password     TEXT        NULL DEFAULT NULL,
      alt_password TEXT        NULL DEFAULT NULL,
      is_guest     INTEGER NOT NULL DEFAULT 1,
      is_admin     INTEGER NOT NULL DEFAULT 0,
      n_attempts   INTEGER NOT NULL DEFAULT 0,
      locked_utc   DATETIME    NULL DEFAULT NULL
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS users_idx1 ON users (email)",
    "INSERT INTO users (user_id, full_name, is_guest) VALUES (0, 'atima', 0)",
    
    
    "CREATE TABLE IF NOT EXISTS biom_files (
      biom_file_id INTEGER PRIMARY KEY,
      file         TEXT    NOT NULL,
      hash         TEXT    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS biom_files_idx1 ON biom_files (hash)",
    "INSERT INTO biom_files (biom_file_id, file, hash) VALUES (0, '', '')",
    
    
    "CREATE TABLE IF NOT EXISTS projects (
      project_id    INTEGER  PRIMARY KEY,
      title         TEXT     NOT NULL,
      orig_bf_id    INTEGER  NOT NULL,
      full_bf_id    INTEGER  NOT NULL,
      rare_bf_id    INTEGER  NOT NULL,
      access_key    TEXT     NOT NULL,
      description   TEXT     NOT NULL DEFAULT '',
      selections    TEXT     NOT NULL DEFAULT '{}',
      n_samples     INTEGER  NOT NULL DEFAULT 0,
      n_taxa        INTEGER  NOT NULL DEFAULT 0, 
      has_tree      INTEGER  NOT NULL DEFAULT 0,
      median_depth  INTEGER  NOT NULL DEFAULT 0,
      meta_colnames TEXT     NOT NULL DEFAULT '[]',
      editors       TEXT     NOT NULL DEFAULT '[]',
      n_views       INTEGER  NOT NULL DEFAULT 0,
      jstree_icon   TEXT     NOT NULL DEFAULT '',
      created_utc   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      
      FOREIGN KEY (orig_bf_id) REFERENCES biom_files (biom_file_id),
      FOREIGN KEY (full_bf_id) REFERENCES biom_files (biom_file_id),
      FOREIGN KEY (rare_bf_id) REFERENCES biom_files (biom_file_id)
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS projects_idx1 ON projects (access_key)",
    
    
    "CREATE TABLE IF NOT EXISTS drafts (
      draft_id    INTEGER  PRIMARY KEY,
      project_id  INTEGER  NOT NULL,
      full_bf_id  INTEGER  NOT NULL,
      rare_bf_id  INTEGER  NOT NULL,
      selections  TEXT     NOT NULL DEFAULT '{}',

      FOREIGN KEY (project_id) REFERENCES projects   (project_id),
      FOREIGN KEY (full_bf_id) REFERENCES biom_files (biom_file_id),
      FOREIGN KEY (rare_bf_id) REFERENCES biom_files (biom_file_id)
    )",
    
    
    "CREATE TABLE IF NOT EXISTS last_access (
      last_access_id INTEGER PRIMARY KEY,
      user_id        INTEGER  NOT NULL,
      project_id     INTEGER  NOT NULL,
      is_starred     INTEGER  NOT NULL DEFAULT 0,
      viewed_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

      FOREIGN KEY (user_id)    REFERENCES users    (user_id),
      FOREIGN KEY (project_id) REFERENCES projects (project_id)
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS last_access_idx1 ON last_access (user_id, project_id)",
    
    
    # A project is public if a user_id = 0 entry exists.
    # Collection location is user-specific.
    "CREATE TABLE IF NOT EXISTS permissions (
      permission_id   INTEGER  PRIMARY KEY,
      user_id         INTEGER  NOT NULL,
      project_id      INTEGER  NOT NULL,
      collection_id   INTEGER      NULL DEFAULT NULL,
      is_editor       INTEGER  NOT NULL DEFAULT 1,
      grantor_user_id INTEGER      NULL DEFAULT NULL,
      
      FOREIGN KEY (user_id)         REFERENCES users       (user_id),
      FOREIGN KEY (grantor_user_id) REFERENCES users       (user_id),
      FOREIGN KEY (project_id)      REFERENCES projects    (project_id),
      FOREIGN KEY (collection_id)   REFERENCES collections (collection_id)
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS permissions_idx1 ON permissions (user_id, project_id)",
    "CREATE        INDEX IF NOT EXISTS permissions_idx2 ON permissions (collection_id)",
    
    
    # A collection is public if user_id = 0.
    "CREATE TABLE IF NOT EXISTS collections (
      collection_id        INTEGER PRIMARY KEY,
      user_id              INTEGER     NULL DEFAULT NULL,
      parent_collection_id INTEGER     NULL DEFAULT NULL,
      jstree_text          TEXT    NOT NULL,
      jstree_icon          TEXT    NOT NULL DEFAULT '',
      
      FOREIGN KEY (user_id)              REFERENCES users       (user_id),
      FOREIGN KEY (parent_collection_id) REFERENCES collections (collection_id)
    )",
    
    
    # Authentication tokens are set/unset by login()/logout().
    # They can be used by any tab for session initialization.
    # Logging out in one tab won't affect others.
    "CREATE TABLE IF NOT EXISTS auth_tokens (
      auth_token_id  INTEGER PRIMARY KEY,
      auth_token_sha TEXT    NOT NULL,
      user_id        INTEGER NOT NULL,

      FOREIGN KEY (user_id) REFERENCES users (user_id)
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS auth_tokens_idx1 ON auth_tokens (auth_token_sha)",
    
    
    # Session tokens are independent between browser tabs.
    # These track both the active user and current project.
    # Set user_id to NULL when user account is deleted.
    "CREATE TABLE IF NOT EXISTS sessions (
      session_id    INTEGER PRIMARY KEY,
      auth_token_id INTEGER      NULL,
      user_id       INTEGER      NULL,
      draft_id      INTEGER      NULL,
      ip_address    TEXT     NOT NULL,
      session_key   TEXT         NULL DEFAULT NULL,
      login_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      logout_utc    DATETIME     NULL DEFAULT NULL,
      heartbeat_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

      FOREIGN KEY (auth_token_id) REFERENCES auth_tokens (auth_token_id),
      FOREIGN KEY (user_id)       REFERENCES users       (user_id),
      FOREIGN KEY (draft_id)      REFERENCES drafts      (draft_id)
    )",
    "CREATE UNIQUE INDEX IF NOT EXISTS sessions_idx1 ON sessions (session_key)",
    
    
    # encrypted data awaiting migration from the previous version of atima
    "CREATE TABLE IF NOT EXISTS migration_user_keys (
      user_id            INTEGER NOT NULL, 
      user_key_salt      TEXT    NOT NULL, 
      encrypted_priv_key TEXT    NOT NULL, 
      priv_key           BLOB        NULL DEFAULT NULL
    )",
    "CREATE TABLE IF NOT EXISTS migration_perm_keys (
      user_id     INTEGER NOT NULL, 
      project_id  INTEGER NOT NULL, 
      key         TEXT    NOT NULL, 
      viewed_utc  TEXT    NOT NULL, 
      unlock      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )",
    "CREATE TABLE IF NOT EXISTS migration_objects (
      project_id  INTEGER NOT NULL, 
      object_name TEXT    NOT NULL, 
      md5         TEXT    NOT NULL, 
      content     BLOB    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS migration_user_keys_idx1 ON migration_user_keys (user_id)",
    "CREATE INDEX IF NOT EXISTS migration_perm_keys_idx1 ON migration_perm_keys (user_id)",
    "CREATE INDEX IF NOT EXISTS migration_perm_keys_idx2 ON migration_perm_keys (project_id)",
    "CREATE INDEX IF NOT EXISTS migration_objects_idx1   ON migration_objects   (project_id)",
    "CREATE INDEX IF NOT EXISTS migration_objects_idx2   ON migration_objects   (object_name)",
    
    
    # Force the next ROWIDs to be larger than old database's.
    "INSERT INTO users (user_id, full_name) VALUES (1000, 'atima2')",
    "INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key) VALUES (10000, 'atima2', 0, 0, 0, '')"
    
  ))
  
  
  sapply(statements, function (sql) {
    tryCatch(
      expr  = dbExecute(DB, sql),
      error = function (e) stop(e, "\n\n", sql) ) 
  })

}


init_db_content <- function (db, config) {
  
  # Load some sample projects; make them public.
  #________________________________________________________
  
  cat(file = stdout(), "Loading rbiom datasets:\n")
  
  req <- list(
    DB      = db,
    CONFIG  = config,
    SESSION = list(user_id = 0L, full_name = "atima") )
  
  TEMP_DIR <- req[['CONFIG']][['temp_dir']]
  
  for (i in c('hmp50', 'gems')) {
    
    cat(file = stdout(), "  - ", i, "\n")
    
    add_project(
      REQ                  = req, 
      requested_access_key = i, 
      infile               = write_biom(
        biom = base::getExportedValue('rbiom', i),
        file = tempfile(tmpdir = TEMP_DIR, fileext = ".json") ))
  }
  
}


