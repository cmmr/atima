#______________________________________________________________________________
#' The route table: every request atima answers, in one place.
#'
#' See `route()` for the meaning of each field. API routes are POSTs under
#' `/api/<area>/<action>`; their arguments arrive as a JSON object, or as a
#' multipart form when a file is uploaded. `viewer` and `editor` refer to the
#' project that is open in the caller's session.
#'
#' The lane is `compute` for anything that may read a BIOM file or call
#' rbiom, and `fast` for work that only touches the database. A `compute`
#' handler hands that work to a worker process as a `job()`. Routes marked
#' `supersede = TRUE` are those where only a session's latest request
#' matters: a new one cancels the one before it.
#'
#' @return A list of `route` objects, in matching order.
#' @noRd
route_table <- function () {

  plot_fns <- c(
    "adiv_boxplot", "adiv_corrplot", "bdiv_boxplot", "bdiv_heatmap",
    "bdiv_ord_plot", "rare_multiplot", "taxa_stacked", "taxa_boxplot",
    "taxa_corrplot", "taxa_heatmap" )

  # Arguments that DataTables sends with every server-side page request.
  dt_args <- list(
    columns = arg_json(optional = TRUE),
    draw    = arg_int(min = 0L, default = 1L),
    start   = arg_int(min = 0L, default = 0L),
    length  = arg_int(min = 1L, max = 1000L, default = 10L),
    search  = arg_json(optional = TRUE),
    order   = arg_json(optional = TRUE) )

  # Free text typed by the user for an account. The account handlers give
  # friendlier messages than the router for values that are too short.
  account_text <- function (...) arg_string(max = 200L, ...)

  list(

    #__________________________________________________________________________
    # Sessions

    route("POST /api/session/init", "api_init_session", "public", "compute", args = list(
      access_key = arg_string(max = 20L, optional = TRUE) )),

    route("POST /api/session/heartbeat", "api_heartbeat", "session", "fast"),

    route("POST /api/session/abort", "api_abort", "session", "fast"),


    #__________________________________________________________________________
    # Accounts (replaced in step 5)

    route("POST /api/account/create", "api_create_account", "session", "fast", args = list(
      full_name   = account_text(),
      email       = account_text(),
      affiliation = account_text(),
      password    = account_text(trim = FALSE, optional = TRUE) )),

    route("POST /api/account/update", "api_update_account", "session", "fast", args = list(
      full_name    = account_text(),
      affiliation  = account_text(),
      new_password = account_text(trim = FALSE),
      password     = account_text(trim = FALSE) )),

    route("POST /api/account/details", "api_account_details", "session", "fast"),

    route("POST /api/account/reset_password", "api_reset_password", "session", "fast", args = list(
      email = account_text() )),

    route("POST /api/account/sign_in", "api_sign_in", "session", "compute", args = list(
      email    = account_text(),
      password = account_text(trim = FALSE) )),

    route("POST /api/account/sign_out", "api_log_out", "session", "compute"),


    #__________________________________________________________________________
    # The open project

    route("POST /api/project/upload", "api_upload_biom", "session", "compute", args = list(
      biom_file = arg_file() )),

    route("POST /api/project/upload_component", "api_upload_component", "viewer", "compute", args = list(
      component      = arg_choice(c("metadata", "taxonomy", "tree")),
      component_file = arg_file() )),

    route("POST /api/project/rarefy", "api_rarefy", "viewer", "compute", supersede = TRUE, args = list(
      depth = arg_int(min = 1L) )),

    route("POST /api/project/save", "api_save", "editor", "compute", args = list(
      title       = arg_string(min = 3L, max = 100L),
      access_key  = arg_string(min = 4L, max = 20L, pattern = access_key_pattern),
      description = arg_string(max = 5000L) )),

    route("POST /api/project/save_as", "api_save_as", "viewer", "compute", args = list(
      title       = arg_string(min = 3L, max = 100L),
      access_key  = arg_string(min = 4L, max = 20L, pattern = access_key_pattern),
      description = arg_string(max = 5000L) )),

    route("POST /api/project/publish", "api_publish", "admin", "compute", args = list(
      is_public     = arg_bool(),
      collection_id = arg_int(min = 1L, optional = TRUE) )),

    route("POST /api/project/export", "api_export", "viewer", "compute", args = list(
      what       = arg_choice(c("original", "metadata", "taxonomy", "tree", "biom", "alpha", "beta", "taxa")),
      sample_set = arg_choice(c("full", "rare"), default = "full"),
      format     = arg_choice(c("json", "hdf5", "tab"), default = "json"),
      method     = arg_string(min = 1L, max = 20L, pattern = "^[A-Za-z0-9\\-]+$", default = "bray"),
      rank       = arg_string(min = 1L, max = 20L, pattern = "^[A-Za-z0-9\\-]+$", default = "otu") )),


    #__________________________________________________________________________
    # The project tree. These act on whichever node is named, so each
    # handler checks that the node belongs to the caller.

    route("POST /api/tree/select", "api_jstree_select", "session", "compute", args = list(
      node_id = arg_node("PG") )),

    route("POST /api/tree/create", "api_jstree_create", "session", "fast", args = list(
      node_id = arg_node("CP", root = TRUE) )),

    route("POST /api/tree/rename", "api_jstree_rename", "session", "fast", args = list(
      node_id = arg_node("CP"),
      text    = arg_string(min = 3L, max = 100L) )),

    route("POST /api/tree/leave", "api_jstree_leave", "session", "fast", args = list(
      node_id = arg_node("P") )),

    route("POST /api/tree/delete", "api_jstree_delete", "session", "fast", args = list(
      node_id = arg_node("CP") )),

    route("POST /api/tree/move", "api_jstree_move", "session", "fast", args = list(
      node_id        = arg_node("CP"),
      parent_node_id = arg_node("C", root = TRUE) )),


    #__________________________________________________________________________
    # Sharing the open project

    route("POST /api/sharing/user_search", "api_sharing_user_search", "session", "fast", args = list(
      query = arg_string(min = 1L, max = 99L, pattern = "^[A-Za-z0-9@_ .\\-]+$") )),

    route("POST /api/sharing/editors", "api_get_editors", "viewer", "fast"),

    route("POST /api/sharing/list", "api_sharing_with", "viewer", "fast"),

    route("POST /api/sharing/update", "api_update_permissions", "viewer", "fast", args = list(
      user_id     = arg_int(min = 1L),
      permissions = arg_choice(c("none", "view", "edit", "any")) )),


    #__________________________________________________________________________
    # Metadata and taxonomy of the open project

    route("POST /api/metadata/table", "api_metadata_dt", "viewer", "compute", supersede = TRUE, args = dt_args),

    route("POST /api/metadata/thead", "api_metadata_thead", "viewer", "compute"),

    route("POST /api/metadata/change_class", "api_metadata_change_class", "viewer", "compute", args = list(
      col_num = arg_int(min = 2L) )),

    route("POST /api/metadata/fields", "api_metadata_fields", "viewer", "compute", args = list(
      mode = arg_choice(c("all", "numeric", "categorical"), default = "all") )),

    route("POST /api/metadata/levels", "api_metadata_levels", "viewer", "compute", args = list(
      field = arg_string(min = 1L, max = 200L, trim = FALSE) )),

    route("POST /api/metadata/minmax", "api_metadata_minmax", "viewer", "compute", args = list(
      field = arg_string(min = 1L, max = 200L, trim = FALSE) )),

    route("POST /api/taxonomy/table", "api_taxonomy_dt", "viewer", "compute", supersede = TRUE, args = dt_args),

    route("POST /api/taxonomy/thead", "api_taxonomy_thead", "viewer", "compute"),


    #__________________________________________________________________________
    # Plots

    route("POST /api/plot", "api_plot", "viewer", "compute", supersede = TRUE, args = list(
      plot_fn     = arg_choice(plot_fns),
      plot_args   = arg_json(),
      depth       = arg_int(min = 1L),
      save_args   = arg_json(optional = TRUE),
      subset_args = arg_json(optional = TRUE),
      attrs       = arg_bool(default = FALSE) )),


    #__________________________________________________________________________
    # BIOM file downloads, fetched by R scripts that have no cookie. The key
    # in the URL is the permission: a project's access key, or the session
    # key of an unsaved draft. (Share-link rules are revisited in step 5.)

    route("GET /unsaved/:session_key/:file", "download_draft_biom", "public", "compute", args = list(
      session_key = arg_string(min = 1L, max = 40L, pattern = "^[A-Za-z0-9]+$"),
      file        = arg_string(pattern = biom_file_pattern) )),

    route("GET /:access_key/:file", "download_project_biom", "public", "compute", args = list(
      access_key = arg_string(min = 4L, max = 20L, pattern = access_key_pattern),
      file       = arg_string(pattern = biom_file_pattern) )),


    #__________________________________________________________________________
    # The single-page app: "/" and "/<access key>" both load index.html.

    route("GET /", "serve_index", "public", "fast", args = list(
      access_key = arg_string(max = 100L, optional = TRUE) )),

    route("GET /:access_key", "serve_index", "public", "fast", args = list(
      access_key = arg_string(max = 100L) ))
  )
}


# A project's access key: 4 to 20 letters, digits and inner hyphens.
access_key_pattern <- "^[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?$"

# Names a BIOM download may have: <rare|full>.<format>[.<compression>]
biom_file_pattern <- "^(rare|full)\\.(tab|json|hdf5)(\\.gz|\\.bz2)?$"
