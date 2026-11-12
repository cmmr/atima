#______________________________________________________________________________
#' Update the rarefaction level.
#' @return list(BIOM), or list() if the project is already at that depth.
#' @noRd
api_rarefy <- function (REQ, depth) {

  job(
    fn   = "work_rarefy",
    args = list(
      ctx   = worker_ctx(REQ[['CONFIG']]),
      full  = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare  = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      depth = depth ),
    finish = function (result) {

      if (!isTRUE(result[['changed']])) return (list())

      update_draft(REQ, rare = result[['rare']])
      list(BIOM = biom_reply(REQ, result[['data']]))
    })
}


#______________________________________________________________________________
#' Overwrites the original project with the working draft.
#' @return list(BIOM)
#' @noRd
api_save <- function (REQ, title, description) {

  job(
    fn   = "work_details",
    args = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]) ),
    finish = function (result) {

      DB      <- REQ[['DB']]
      details <- result[['details']]

      # Copy data from draft to parent project.
      db_update(
        DB            = DB,
        table         = "projects",
        id            = REQ[['SESSION']][['project_id']],
        err_code      = "ASave1",
        title         = title,
        full_bf_id    = REQ[['SESSION']][['full_bf_id']],
        rare_bf_id    = REQ[['SESSION']][['rare_bf_id']],
        description   = description,
        n_samples     = details[['n_samples']],
        n_taxa        = details[['n_taxa']],
        has_tree      = details[['has_tree']],
        median_depth  = details[['median_depth']],
        meta_colnames = details[['meta_colnames']] %>% toJSON() )

      # Reload this project on the client side.
      resume_session(REQ)

      list(BIOM = biom_reply(REQ, result[['data']]))
    })
}


#______________________________________________________________________________
#' Copy this draft to a new project_id. The copy is private, with a private
#' key of its own, and the caller is its editor.
#'
#' @return list(BIOM, tree_node)
#' @noRd
api_save_as <- function (REQ, title, description) {

  job(
    fn   = "work_details",
    args = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]) ),
    finish = function (result) {

      DB       <- REQ[['DB']]
      session  <- REQ[['SESSION']]
      user_id  <- session[['user_id']]
      details  <- result[['details']]

      # Fetch the current project values.
      sql     <- "SELECT * FROM projects WHERE project_id = ?"
      project <- db_query(DB, sql, "ASAs2", list(session[['project_id']]), req1 = TRUE)

      # Merge into a new project record.
      project_id <- db_insert(
        DB            = DB,
        table         = "projects",
        err_code      = "ASAs3",
        project_id    = NULL,
        defaults      = project,
        title         = title,
        full_bf_id    = session[['full_bf_id']],
        rare_bf_id    = session[['rare_bf_id']],
        access_key    = new_access_key(DB),
        description   = description,
        n_samples     = details[['n_samples']],
        n_taxa        = details[['n_taxa']],
        has_tree      = details[['has_tree']],
        median_depth  = details[['median_depth']],
        meta_colnames = details[['meta_colnames']] %>% toJSON(),
        editors       = toJSON(session[['full_name']]),
        n_views       = 1L,
        public_key    = NULL,
        public_collection_id = NULL )

      # Update the draft to point to the new project.
      sql <- "UPDATE drafts set project_id = ? WHERE draft_id = ?"
      db_query(DB, sql, "ASAs4", list(project_id, session[['draft_id']]))

      # Grant editor permissions to this user.
      sql <- "INSERT INTO permissions (user_id, project_id) VALUES (?, ?)"
      permission_id <- db_query(DB, sql, "ASAs5", list(user_id, project_id))

      sql <- "INSERT INTO last_access (user_id, project_id) VALUES (?, ?)"
      db_query(DB, sql, "ASAs6", list(user_id, project_id))

      # Fetch information for displaying in the collections.
      sql <- paste0(
        "SELECT * FROM permissions",
        " LEFT JOIN projects USING (project_id)",
        " WHERE permission_id = ?" )
      row <- db_query(DB, sql, "ASAs7", list(permission_id))

      # Reload this project on the client side.
      resume_session(REQ)

      list(
        BIOM        = biom_reply(REQ, result[['data']]),
        tree_node = tree_node(row) )
    })
}


#______________________________________________________________________________
#' Changes the project associated with the current session. The router has
#' already checked that the caller may read the project.
#' @return invisible(NULL)
#' @noRd
select_project <- function (REQ, project_id) {

  DB         <- REQ[['DB']]
  session_id <- REQ[['SESSION']][['session_id']]

  # Create a new draft for this project.
  db_update(
    DB       = DB,
    table    = 'sessions',
    id       = session_id,
    err_code = "SProj2",
    draft_id = create_draft(DB, project_id) )

  resume_session(REQ)

  invisible()
}



#______________________________________________________________________________
#' Insert a newly imported project into the SQL tables.
#'
#' The session's user becomes the project's first editor. With no user in
#' the session (first-run seeding) the project has no editors.
#'
#' @param imported    What `work_import()` returned: the three stored files
#'                    and the project's details.
#' @param public_key  Make the project public, under this key.
#' @return a project_id.
#' @noRd
add_project <- function (REQ, imported, collection_id = NULL, public_key = NULL) {

  DB        <- REQ[['DB']]
  user_id   <- REQ[['SESSION']][['user_id']]
  full_name <- REQ[['SESSION']][['full_name']]
  details   <- imported[['details']]

  if (!is.null(public_key)) check_public_key(DB, public_key)

  project_id <- db_insert(
    DB            = DB,
    table         = "projects",
    err_code      = "AProj1",
    title         = details[['title']],
    orig_bf_id    = register_biom_file(DB, imported[['orig']]),
    full_bf_id    = register_biom_file(DB, imported[['full']]),
    rare_bf_id    = register_biom_file(DB, imported[['rare']]),
    access_key    = new_access_key(DB),
    public_key    = public_key,
    # The description comes from the uploaded file, by way of pandoc.
    description   = sanitize_html(details[['description']]),
    n_samples     = details[['n_samples']],
    n_taxa        = details[['n_taxa']],
    has_tree      = details[['has_tree']],
    median_depth  = details[['median_depth']],
    meta_colnames = details[['meta_colnames']] %>% toJSON(),
    editors       = toJSON(full_name) )

  # Put into the user's top level collection by default.
  if (!is.null(user_id))
    db_insert(DB, "permissions", "AProj2", project_id, user_id, collection_id)

  return (project_id)
}


#______________________________________________________________________________
#' Copy an existing project to a working draft.
#'
#' @return draft_id
#' @noRd
create_draft <- function (DB, project_id) {


  #________________________________________________________
  # Increment this project's number of views.
  #________________________________________________________
  sql <- "UPDATE projects SET n_views = n_views + 1 WHERE project_id = ?"
  db_query(DB, sql, "CDraf1", list(project_id))


  #________________________________________________________
  # Get the project data for copying to a draft.
  #________________________________________________________
  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "CDraf2", list(project_id), req1 = TRUE)


  #________________________________________________________
  # Duplicate the project to a draft.
  #________________________________________________________
  draft_id <- db_insert(
    DB         = DB,
    table      = "drafts",
    err_code   = "OProj2",
    project_id = project_id,
    full_bf_id = project[['full_bf_id']],
    rare_bf_id = project[['rare_bf_id']] )

  return (draft_id)
}



#______________________________________________________________________________
# Project keys.
#
# Both kinds of key appear in the same place in URLs (`/<key>`), so no key
# may be in use as either kind by another project.
#______________________________________________________________________________

# Path segments that mean something else to the router or to httpuv.
reserved_keys <- c("api", "auth", "www", "tmp", "unsaved")

# A public key: 4 to 20 lower-case letters, digits and inner hyphens.
public_key_pattern <- "^[a-z0-9][a-z0-9\\-]{2,18}[a-z0-9]$"

# Characters in a new private key. Twelve of 36 symbols is 62 bits: enough
# that keys cannot be found by guessing over HTTP.
access_key_length <- 12L


#' Is a key already some project's private key, or the public key of a
#' project other than `project_id`?
#' @noRd
key_in_use <- function (DB, key, project_id = NULL) {
  sql <- "SELECT COUNT(*) FROM projects WHERE access_key = ? OR (public_key = ? AND project_id != ?)"
  db_query(DB, sql, "KUse1", list(key, key, project_id %||% -1L)) > 0
}


#______________________________________________________________________________
#' A new random private key that no project uses.
#' @return an access_key
#' @noRd
new_access_key <- function (DB) {

  for (i in 1:10) {
    access_key <- random_key(access_key_length)
    if (!key_in_use(DB, access_key)) return (access_key)
  }

  stop("Unable to generate a unique access key.")
}


#______________________________________________________________________________
#' Give the open project a new private key. Every link made with the old
#' one stops working; people who were granted the project keep it.
#' @return list(access_key)
#' @noRd
api_new_key <- function (REQ) {

  DB         <- REQ[['DB']]
  access_key <- new_access_key(DB)

  db_update(DB, "projects", REQ[['SESSION']][['project_id']], "ANKey1", access_key = access_key)
  resume_session(REQ)

  list(access_key = unbox(access_key))
}


#______________________________________________________________________________
#' Stop unless a public key is well formed and free.
#' @param project_id  The project that is to have the key.
#' @noRd
check_public_key <- function (DB, public_key, project_id = NULL) {

  if (!isTRUE(grepl(public_key_pattern, public_key, perl = TRUE)))
    stop_user("A public key is 4 to 20 lower-case letters, digits and hyphens, and starts and ends with a letter or digit.")

  if (public_key %in% reserved_keys)
    stop_user("That public key is reserved. Please choose another.")

  if (key_in_use(DB, public_key, project_id))
    stop_user("That public key is already in use. Please choose another.")

  invisible(TRUE)
}


#______________________________________________________________________________
#' Make the open project public or private.
#'
#' A project is public while it has a public key. Its private key is not
#' changed by publishing or unpublishing, so share links keep working.
#'
#' @param is_public      Should everyone be able to read the project?
#' @param public_key     The key to publish it under. Needed the first time;
#'                       left out, a public project keeps the key it has.
#' @param collection_id  The public collection to list it under, or `NULL`
#'                       for the top of the public tree.
#' @return list(BIOM, tree)
#' @noRd
api_publish <- function (REQ, is_public, public_key = NULL, collection_id = NULL) {

  DB         <- REQ[['DB']]
  project_id <- REQ[['SESSION']][['project_id']]

  if (is_public) {

    current    <- REQ[['SESSION']][['public_key']]
    public_key <- public_key %||% if (!is.na(current)) current

    if (is.null(public_key))
      stop_user("Choose a public key to publish this project under.")

    check_public_key(DB, public_key, project_id)

    if (!is.null(collection_id)) {
      sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id IS NULL"
      if (db_query(DB, sql, "APub1", list(collection_id)) == 0)
        stop_user("That is not a public collection.")
    }

  } else {
    public_key    <- NULL
    collection_id <- NULL
  }

  db_update(
    DB                   = DB,
    table                = "projects",
    id                   = project_id,
    err_code             = "APub2",
    public_key           = public_key,
    public_collection_id = collection_id )

  resume_session(REQ)

  with_biom_data(REQ, function (BIOM) list(
    BIOM        = BIOM,
    tree        = tree_data(REQ) ))
}
