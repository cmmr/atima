# 
# bcrypt is crashes atima if it gets loaded before curl/openssl,
# so now we are using scrypt via the R sodium package. Since we
# can't run bcrypt::checkpw(), migrating isn't possible.
# 
# 
# 
# # CREATE DATABASE atima;
# # CREATE USER migrate@localhost IDENTIFIED BY 'migrate';
# # GRANT SELECT ON atima.* TO 'migrate'@'localhost' IDENTIFIED BY 'migrate';
# 
# 
# #______________________________________________________________________________
# #' Copy one project from old DB to new DB.
# #' @return list(node)
# api_migrate_project <- function (REQ, project_id, key) {
#   
#   DB       <- REQ[['DB']]
#   TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]
#   user_id  <- REQ[['SESSION']][['user_id']]
#   
#   project_id <- int(project_id)
#   stopifnot(is_scalar_character(key))
#   
#   
#   #________________________________________________________
#   # Log non-fatal errors to stderr.
#   #________________________________________________________
#   log_error <- function (..., e = NULL) {
#     if (!is.null(e)) e <- paste("\nError:", as.character(e))
#     warning(
#       "In api_migrate_project(project_id = ", project_id, "): \n", 
#       ..., ".\nSkipping migration of this project.", e, "\n\n")
#   }
#   
#   
#   #________________________________________________________
#   # Lock this migration task for one hour.
#   #________________________________________________________
#   tryCatch(
#     
#     expr = local({
#       
#       db_query(DB, "BEGIN", "AMProj1")
#       
#       sql <- paste0(
#         "SELECT COUNT(*) FROM migration_perm_keys WHERE", 
#         " user_id = ? AND project_id = ? AND unlock <= CURRENT_TIMESTAMP" )
#       n <- db_query(DB, sql, "AMProj2", list(user_id, project_id))
#       
#       if (identical(n, 0L)) {
#         db_query(DB, "COMMIT", "AMProj3")
#         return (list('node' = unbox(NULL)))
#       }
#       
#       sql <- paste0(
#         "UPDATE migration_perm_keys",
#         " SET unlock = datetime('now', '+1 hour')",
#         " WHERE project_id = ?" )
#       db_query(DB, sql, "AMProj4", list(project_id))
#       
#       
#       db_query(DB, "COMMIT", "AMProj5")
#       
#     }), 
#     
#     error = function (e) {
#       try(silent = TRUE, db_query(DB, "ROLLBACK", "AMProj6"))
#       stop("Error locking project for migration. ", e)
#     })
#   
#   
#   
#   #________________________________________________________
#   # Decrypt the objects.
#   #________________________________________________________
#   
#   EncryptionKey <- key %>% openssl::base64_decode() %>% unserialize()
#   
#   sql <- "SELECT * FROM migration_objects WHERE project_id = ?"
#   res <- db_query(DB, sql, "AMProj7", list(project_id), simplify = FALSE)
#   
#   if (!'Biom Data' %in% res[['object_name']])
#     stop("No 'Biom Data' object available for project id ", project_id)
#   
#   
#   objs <- list()
#   for (i in seq_len(nrow(res))) {
#     
#     n <- res[i, 'object_name']
#     
#     
#     # Check for data corruption
#     #________________________________________________________
#     if (!identical(n, 'Project Name'))
#       tryCatch(
#         expr = {
#           old_md5 <- res[i, 'md5']
#           new_md5 <- res[i, 'content'][[1]] %>%
#             openssl::base64_encode() %>%
#             openssl::md5() %>% 
#             as.character()
#           if (!identical(old_md5, new_md5))
#             stop("MD5 sums don't match: ", old_md5, " vs ", new_md5)
#         }, 
#         error = function (e) {
#           stop(n, " for project id ", project_id, " has data corruption. ", e)
#         })
#     
#     
#     # Decode the object using encryption key.
#     #________________________________________________________
#     objs[[n]] <- tryCatch(
#       expr = {
#         res[i, 'content'][[1]] %>%
#           unserialize() %>%
#           aes_gcm_decrypt(key=EncryptionKey) %>%
#           memDecompress(type="bzip2") %>%
#           unserialize()
#       }, 
#       error = function (e) {
#         stop("Can't decrypt '", n, "' object for project id ", project_id, ": ", e)
#       })
#   }
#   
#   objs <- objs[!sapply(objs, identical, y = NA)]
#   objs <- objs[!sapply(objs, identical, y = NULL)]
#   
#   
#   
#   #________________________________________________________
#   # Assemble the BIOM objects.
#   #________________________________________________________
#   
#   tmp <- tempfile(tmpdir = TEMP_DIR)
#   on.exit(unlink(tmp), add = TRUE)
#   
#   file_obj <- objs[['Biom Data']]
#   if (identical(file_obj[[1]], charToRaw("{"))) file_obj <- rawToChar(file_obj)
#   if (is.character(file_obj)) { writeChar(object = file_obj, con = tmp, eos = NULL)
#   } else                      { writeBin( object = file_obj, con = tmp) }
#   full_obj <- as_rbiom(biom = tmp)
#   full_obj$comment <- ''
#   
#   
#   if (hasName(objs, 'Project Name')) full_obj$id       <- objs[['Project Name']]
#   if (hasName(objs, 'Metadata'))     full_obj$metadata <- objs[['Metadata']]
#   if (hasName(objs, 'Taxonomy'))     full_obj$taxonomy <- objs[['Taxonomy']]
#   if (hasName(objs, 'Tree'))         full_obj$tree     <- objs[['Tree']]
#   
#   rare_obj <- rarefy(full_obj, depth = objs[['Rarefaction Level']] %||% 0.1)
#   details  <- biom_to_details(biom = full_obj)
#   
#   
#   #________________________________________________________
#   # Get the names for all the editors of this project.
#   #________________________________________________________
#   sql <- paste0(
#     "SELECT full_name FROM",
#     " permissions LEFT JOIN users USING(user_id)",
#     " WHERE project_id = ? AND is_editor = 1")
#   editors <- db_query(DB, sql, "AMProj8", list(project_id))
#   
#   
#   #________________________________________________________
#   # Save to `projects` and `objects` SQL tables.
#   #________________________________________________________
#   db_update(
#     DB            = DB,
#     table         = "projects",
#     id            = project_id,
#     err_code      = "AMProj9",
#     title         = details[['title']],
#     description   = details[['description']],
#     orig_bf_id    = store_file(REQ, tmp), 
#     full_bf_id    = store_biom(REQ, full_obj), 
#     rare_bf_id    = store_biom(REQ, rare_obj), 
#     access_key    = substr(openssl::md5(EncryptionKey), 1, 12), 
#     n_samples     = details[['n_samples']],
#     n_taxa        = details[['n_taxa']], 
#     has_tree      = details[['has_tree']],
#     median_depth  = details[['median_depth']],
#     meta_colnames = details[['meta_colnames']] %>% if.null(list()) %>% toJSON(),
#     editors       = editors %>% if.null(list()) %>% toJSON() )
#     
#   
#   
#   
#   #________________________________________________________
#   # Delete this migration task.
#   #________________________________________________________
#   sql <- "DELETE FROM migration_perm_keys WHERE project_id = ?"
#   db_query(DB, sql, "AMProj10", list(project_id))
#   
#   sql <- "DELETE FROM migration_objects WHERE project_id = ?"
#   db_query(DB, sql, "AMProj11", list(project_id))
#   
#   
#   
#   #________________________________________________________
#   # The node definition to send back to jsTree.
#   #________________________________________________________
#   sql  <- paste0(
#     "SELECT * FROM permissions", 
#     " LEFT JOIN projects USING (project_id)",
#     " WHERE user_id = ? AND project_id = ?" )
#   row  <- db_query(DB, sql, "AMProj12", list(user_id, project_id))
#   jstree_node <- compile_jstree_node(DB, row)
#   
#   
#   return (list('node' = jstree_node))
# }
# 
# 
# 
# #______________________________________________________________________________
# #' Port the old atima database into the new one.
# migration_init <- function (new_db) {
#   
#   cat(file = stdout(), "Migrating data:\n")
#   
#   old_db <- dbConnect(
#     drv      = RMariaDB::MariaDB(),
#     dbname   = "atima",
#     host     = "localhost",
#     port     = "3306",
#     user     = Sys.getenv("ATIMA_LEGACY_DB_USER"),
#     password = Sys.getenv("ATIMA_LEGACY_DB_PASSWORD"),
#     bigint   = "numeric" )
#   
#   on.exit(dbDisconnect(old_db))
#   
#   
#   #________________________________________________________
#   # Users
#   #________________________________________________________
#   
#   cat(file = stdout(), "  - Users\n")
#   
#   sql   <- "SELECT * FROM users WHERE `Email Address` IS NOT NULL"
#   users <- dbGetQuery(old_db, sql)
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `users`",
#       " (`user_id`, `full_name`, `affiliation`, `email`, `password`, `is_guest`)", 
#       " VALUES (?,?,?,?,?,0)" ), 
#     params    = list(
#       users[['UserID']],
#       users[['Full Name']],
#       users[['Affiliation']],
#       users[['Email Address']],
#       users[['Hashed Password']] ))
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `migration_user_keys`",
#       " (`user_id`, `user_key_salt`, `encrypted_priv_key`) VALUES (?,?,?)" ), 
#     params    = list(
#       users[['UserID']], 
#       users[['User Key Salt']], 
#       users[['Private Key']] ))
#   
#   
#   return (invisible())
#   
#   
#   #________________________________________________________
#   # Projects
#   #________________________________________________________
#   
#   cat(file = stdout(), "  - Projects\n")
#   
#   sql      <- "SELECT * FROM projects WHERE DELETED IS NULL"
#   projects <- dbGetQuery(old_db, sql)
#   projects <- projects[projects[['Created By']] %in% users[['UserID']],,drop=FALSE]
#   
#   project_id  <- projects[['ProjectID']]
#   created_utc <- as.character(projects[['Created']])
#   access_key  <- replicate(length(project_id), random_string(12))
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `projects`",
#       " (`project_id`, `created_utc`, `title`, `orig_bf_id`, `full_bf_id`, `rare_bf_id`, `access_key`)", 
#       " VALUES (?,?,' - Queued for migration - ',0,0,0,?)" ), 
#     params    = list(project_id, created_utc, access_key))
#   
#   
#   #________________________________________________________
#   # Objects
#   #________________________________________________________
#   
#   cat(file = stdout(), "  - Objects\n")
#   
#   for (i in seq_len(nrow(projects))) {
#     
#     tryCatch(
#       
#       expr = {
#         
#         # Pull base64-encoded objects out of the old database.
#         #________________________________________________________
#         objects <- dbGetQuery(
#           conn      = old_db, 
#           statement = paste0(
#             "SELECT `Object Name`, `md5sum`, `Base64`",
#             " FROM objects WHERE ProjectID = ?" ), 
#           params    = list(projects[i, 'ProjectID']) )
#         
#         
#         # Import encrypted objects as blobs.
#         #________________________________________________________
#         for (j in seq_len(nrow(objects))) {
#           dbExecute(
#             conn      = new_db, 
#             statement = paste0(
#               "INSERT INTO `migration_objects`",
#               " (`project_id`, `object_name`, `md5`, `content`) VALUES (?,?,?,?)" ), 
#             params    = list(
#               projects[i, 'ProjectID'],
#               objects[j, 'Object Name'],
#               objects[j, 'md5sum'],
#               list(openssl::base64_decode(objects[j, 'Base64']))
#             ))
#         }
#     },
#     
#     error = function (e) {
#       warning("Unable to import ProjectID ", projects[i, 'ProjectID'], ".\n", e)
#       
#       dbExecute(
#         conn      = new_db, 
#         statement = "DELETE FROM projects WHERE project_id = ?", 
#         params    = list(projects[i, 'ProjectID']) )
#       
#       dbExecute(
#         conn      = new_db, 
#         statement = "DELETE FROM migration_objects WHERE project_id = ?", 
#         params    = list(projects[i, 'ProjectID']) )
#       
#       projects[i, 'ProjectID'] <- NA
#     })
#   }
#   
#   
#   
#   #________________________________________________________
#   # Permissions
#   #________________________________________________________
#   
#   cat(file = stdout(), "  - Permissions\n")
#   
#   sql   <- "SELECT * FROM permissions"
#   perms <- dbGetQuery(old_db, sql)
#   perms <- perms[perms[['UserID']]    %in% users[['UserID']]      ,,drop=FALSE]
#   perms <- perms[perms[['ProjectID']] %in% projects[['ProjectID']],,drop=FALSE]
#   perms[which(!perms[['Modified By']] %in% users[['UserID']]), 'Modified By'] <- NA
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `permissions`",
#       " (`user_id`, `project_id`, `is_editor`, `grantor_user_id`)",
#       " VALUES (?,?,?,?)" ), 
#     params    = list(
#       perms[['UserID']],
#       perms[['ProjectID']],
#       perms[['Editor']],
#       perms[['Modified By']] ))
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `last_access`",
#       " (`user_id`, `project_id`, `viewed_utc`)",
#       " VALUES (?,?,?)" ), 
#     params    = list(
#       perms[['UserID']],
#       perms[['ProjectID']],
#       as.character(perms[['Last Access']]) ))
#   
#   dbExecute(
#     conn      = new_db, 
#     statement = paste0(
#       "INSERT INTO `migration_perm_keys`",
#       " (`user_id`, `project_id`, `key`, `viewed_utc`) VALUES (?,?,?,?)" ), 
#     params    = list(
#       perms[['UserID']],
#       perms[['ProjectID']],
#       perms[['Encryption Key']],
#       as.character(perms[['Last Access']]) ))
#   
# }
# 
# 
# 
# #______________________________________________________________________________
# #' On first sign in, migrate the user's rsa keys.
# migrate_priv_key <- function (DB, user_id, password) {
#   
#   
#   #________________________________________________________
#   # See if this user's projects need to be migrated.
#   #________________________________________________________
#   sql <- paste0(
#     "SELECT user_key_salt, encrypted_priv_key",
#     " FROM migration_user_keys",
#     " WHERE user_id = ? AND priv_key IS NULL" )
#   keys <- db_query(DB, sql, "MPKey1", list(user_id))
#   
#   if (is.null(keys)) return (NULL)
#   
#   
#   
#   #________________________________________________________
#   # Decrypt `encrypted_priv_key` to `priv_key`.
#   #________________________________________________________
#   tryCatch(
#     expr = {
#       
#       UserKey <- keys[['user_key_salt']] %>%
#         password_store(password, .) %>%
#         substr(30, 61) %>%
#         openssl::base64_decode() %>%
#         openssl::sha256()
#       
#       PrivateKey <- keys[['encrypted_priv_key']] %>%
#         openssl::base64_decode() %>%
#         unserialize() %>%
#         aes_gcm_decrypt(key=UserKey) %>%
#         unserialize()
#     },
#     error = function (e) {
#       stop("Error decoding keys for user_id ", user_id,": ", e)
#     })
#   
#   
#   #________________________________________________________
#   # Store the decrypted version back to the database.
#   #________________________________________________________
#   sql    <- "UPDATE migration_user_keys SET priv_key = ? WHERE user_id = ?"
#   params <- list(list(serialize(PrivateKey, NULL)), user_id)
#   db_query(DB, sql, "MPKey2", params)
#   
#   return (NULL)
# }
# 
# 
# 
# #______________________________________________________________________________
# #' List all the un-migrated projects.
# #' @return lapply(project_id, title, key)
# migration_queue <- function (REQ) {
#   
#   return (list())
#   
#   DB       <- REQ[['DB']]
#   user_id  <- REQ[['SESSION']][['user_id']]
#   is_guest <- REQ[['SESSION']][['is_guest']]
#   
#   if (isTRUE(is_guest)) return (list())
#   
#   tryCatch(error = function (e) { stop("In migration_queue: ", e) }, {
#     
#     
#     #________________________________________________________
#     # See if this user is in the migration tables.
#     #________________________________________________________
#     PrivateKey <- tryCatch(
#       
#       expr = local({
#         
#         sql <- paste0(
#           "SELECT priv_key FROM migration_user_keys ",
#           " WHERE user_id = ? AND priv_key IS NOT NULL" )
#         res <- db_query(DB, sql, "MQueu1", list(user_id), simplify = FALSE)
#         
#         if (nrow(res) == 0) { return (NULL)
#         } else              { return (unserialize(res[1,1][[1]])) }
#       }),
#       
#       error = function (e) {
#         warning(
#           "Can't fetch PrivateKey for user_id ", user_id, ".\n",
#           "Skipping migration.\nError:", e, "\n\n")
#         return (list())
#       })
#     
#     if (is.null(PrivateKey)) return (list())
#     
#     
#     
#     
#     #________________________________________________________
#     # Pull project_id/key/title for un-migrated projects.
#     #________________________________________________________
#     sql <- paste0(
#       "SELECT project_id, key FROM migration_perm_keys ",
#       " WHERE user_id = ? ORDER BY viewed_utc DESC" )
#     projects <- db_query(DB, sql, "MQueu2", list(user_id), simplify = FALSE)
#     
#     # Separate query for projects without 'Project Name' objects.
#     sql <- paste0(
#       "SELECT project_id, content",
#       " FROM migration_perm_keys LEFT JOIN migration_objects USING (project_id)",
#       " WHERE user_id = ? AND object_name = 'Project Name'" )
#     objects <- db_query(DB, sql, "MQueu3", list(user_id), simplify = FALSE)
#     
#     
#     
#     #________________________________________________________
#     # Nothing to migrate - clean up migration_user_keys.
#     #________________________________________________________
#     if (nrow(projects) == 0) {
#       
#       sql <- "DELETE FROM migration_user_keys WHERE user_id = ?"
#       db_query(DB, sql, "MQueu4", list(user_id))
#       
#       return (list())
#     }
#     
#     
#     
#     #________________________________________________________
#     # Only decode the project titles for now.
#     #________________________________________________________
#     queue <- lapply(seq_len(nrow(projects)), function (i) {
#       
#       project_id <- projects[i, 'project_id']
#       
#       EncryptionKey <- tryCatch({
#          projects[i, 'key'] %>%
#           openssl::base64_decode() %>%
#           openssl::rsa_decrypt(key=PrivateKey) %>%
#           unserialize()
#         },
#         error = function (e) {
#           warning(
#             "Can't decode EncryptionKey for project_id ", project_id, ".\n",
#             "Skipping project.\nError:", e, "\n\n")
#           return (NULL)
#         })
#       
#       title <- tryCatch(local({
#           
#           j <- which(objects[['project_id']] == project_id)
#           if (is.null(j)) return ("Untitled")
#           
#           title <- objects[j, 'content'][[1]] %>%
#             unserialize() %>%
#             aes_gcm_decrypt(key=EncryptionKey) %>%
#             memDecompress(type="bzip2") %>%
#             unserialize()
#           
#           stopifnot(is_scalar_character(title))
#           return (title)
#         }), 
#         error = function (e) {
#           warning(
#             "Can't decode Project Name for project_id ", project_id, ".\n",
#             "Skipping project.\nError:", e, "\n\n")
#           return (NULL)
#         })
#       
#       
#       return (list(
#         project_id = unbox(project_id), 
#         title      = unbox(title),
#         key        = unbox(EncryptionKey %>% serialize(NULL) %>% openssl::base64_encode()) ))
#     })
#     
#     queue <- queue[!sapply(queue, is.null)]
#   
#   })
#   
#   return (queue)
# }
# 
# 
# 
# 
# # Enable backwards compatibility with IVs > 12 bytes.
# 
# aes_gcm_decrypt <- function (data, key, iv=NULL) {
#   if (is.null(iv)) iv <- head(attr(data, "iv"), 12)
#   openssl::aes_gcm_decrypt(data, key, iv)
# }
# aes_gcm_encrypt <- function (data, key, iv=NULL) {
#   if (is.null(iv)) iv <- openssl::rand_bytes(12)
#   openssl::aes_gcm_encrypt(data, key, iv)
# }
# 
# 
