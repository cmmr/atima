# garbage collector


run_garbage_collector <- function (req) {
  
  DATA_DIR <- REQ[['CONFIG']][['data_dir']]
  TEMP_DIR <- req[['CONFIG']][['temp_dir']]
  
  
  #________________________________________________________
  # Create a 'DATA_DIR/gc' file.
  #________________________________________________________
  gc_file <- file.path(DATA_DIR, "gc")
  if (!file.exists(gc_file)) {
    if (!dir.exists(DATA_DIR)) dir.create(DATA_DIR, recursive = TRUE)
    cat(file = gc_file, "modification time = last garbage collection")
  }
  
  
  #________________________________________________________
  # Only run once every an hour.
  #________________________________________________________
  last_gc <- as.numeric(file.mtime(gc_file))
  curr_ts <- as.numeric(Sys.time())
  if (last_gc >= curr_ts - (60 * 60)) return (NULL)
  Sys.setFileTime(gc_file, Sys.time())
  
  
  #________________________________________________________
  # Execute in a future to not block the main thread.
  #________________________________________________________
  #future_promise({
    
    
    #________________________________________________________
    # db_connect to database.
    #________________________________________________________
    DB <- db_connect(REQ[['CONFIG']][['data_dir']])
    on.exit(db_close(DB))
    
    
    #________________________________________________________
    # Kill jobs that have been running for > 15 minutes.
    #________________________________________________________
    local({
      
      sql     <- "SELECT job_id FROM jobs WHERE start_utc < date('now', ?)"
      timeout <- Sys.getenv('TIMEOUT')
      if (nchar(timeout) == 0) { timeout <- "-15 minutes"
      } else                   { timeout <- paste0("-", timeout) }
      job_ids <- db_query(DB, sql, "RGColl1", list(timeout))
      
      for (job_id in job_ids)
        interrupt_job(DB, job_id = job_id)
      
    })
    
    
    #________________________________________________________
    # Delete temp files that are older than 30 minutes.
    #________________________________________________________
    local({
      
      tfiles <- list.files(TEMP_DIR, full.names = TRUE, recursive = TRUE)
      mtimes <- as.integer(file.mtime(tfiles))
      oldies <- tfiles[which(as.integer(Sys.time()) - mtimes > 60 * 30)]
      file.remove(oldies)
      
      for (tdir in rev(list.dirs(TEMP_DIR)))
        if (length(list.files(tdir, include.dirs = TRUE)) == 0)
          unlink(tdir, recursive = TRUE)
    })
    
    
    #________________________________________________________
    # Log out abandoned sessions (no heartbeat for a week).
    #________________________________________________________
    local({
      
      sql <- paste0(
        "SELECT session_id, user_id FROM sessions",
        " WHERE heartbeat_utc < date('now', '-1 week')" )
      sessions <- db_query(DB, sql, "RGColl2", simplify = FALSE)
      
      for (i in seq_len(nrow(sessions))) {
        
        session_id <- sessions[i, 'session_id']
        user_id    <- sessions[i, 'user_id']
        
        interrupt_job(DB, session_id = session_id)
        
        sql <- paste0(
          "UPDATE sessions SET",
          " logout_utc = heartbeat_utc,",
          " project_id = NULL",
          " WHERE session_id = ?")
        db_query(DB, sql, "RGColl3", list(session_id))
        
      }
      
    })
    
    
    #________________________________________________________
    # Delete guest users who have no active sessions.
    #________________________________________________________
    local({
      
      sql <- paste0(
        "SELECT DISTINCT user_id FROM sessions",
        " WHERE user_id IS NOT NULL AND logout_utc IS NULL" )
      active_uids <- db_query(DB, sql, "RGColl4")
      
      sql <- "SELECT DISTINCT user_id FROM users WHERE is_guest = 1"
      guest_uids <- db_query(DB, sql, "RGColl5")
      
      for (user_id in setdiff(guest_uids, active_uids))
        delete_account(DB, user_id)
      
    })
    
    
    
    #________________________________________________________
    # Delete projects if no one has permissions to them.
    #________________________________________________________
    local({
      
      sql <- paste0(
        "SELECT DISTINCT project_id FROM permissions",
        " WHERE project_id IS NOT NULL" )
      usr_pids <- db_query(DB, sql, "RGColl6")
      
      sql      <- "SELECT project_id, parent_project_id FROM projects"
      projects <- db_query(DB, sql, "RGColl7", simplify = FALSE)
      all_pids <- unique(c(
        projects[['project_id']], 
        projects[['parent_project_id']] ))
      all_pids <- all_pids[!is.na(all_pids)]
      
      for (project_id in setdiff(all_pids, usr_pids)) {
        
        sql <- "UPDATE sessions SET project_id = NULL WHERE project_id = ?"
        db_query(DB, sql, "RGColl8", list(project_id))
        
        sql <- "DELETE FROM projects WHERE project_id = ?"
        db_query(DB, sql, "RGColl9", list(project_id))
      }
      
    })
    
    
    #________________________________________________________
    # Delete objects that no project uses.
    #________________________________________________________
    local({
      
      sql <- paste0(
        "SELECT DISTINCT biom_file_id FROM objects",
        " WHERE biom_file_id IS NOT NULL" )
      all_oids <- db_query(DB, sql, "RGColl10")
      
      sql      <- "SELECT orig_bf_id, full_bf_id, rare_bf_id FROM projects"
      projects <- db_query(DB, sql, "RGColl11", simplify = FALSE)
      ref_oids <- unique(c(
        projects[['orig_bf_id']], 
        projects[['full_bf_id']], 
        projects[['rare_bf_id']] ))
      ref_oids <- ref_oids[!is.na(ref_oids)]
      
      rm_object_ids <- setdiff(all_oids, ref_oids)
      
      if (length(rm_object_ids) > 0) {
        
        sql <- "DELETE FROM objects WHERE biom_file_id = ?"
        for (biom_file_id in rm_object_ids)
          db_query(DB, sql, "RGColl12", list(biom_file_id))
        
        objects_dir <- file.path(DATA_DIR, "objects")
        file.remove(sapply(rm_object_ids, int_to_path, dir = objects_dir))
        
        for (dir in rev(list.dirs(objects_dir)))
          if (length(list.files(dir, include.dirs = TRUE)) == 0)
            unlink(dir, recursive = TRUE)
      }
      
    })
    
  #})
  
}
