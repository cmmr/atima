#______________________________________________________________________________
#' The route table: every request atima answers, in one place.
#'
#' See `route()` for the meaning of each field. API routes are POSTs under
#' `/api/<area>/<action>`; their arguments arrive as a JSON object, or as a
#' multipart form when a file is uploaded. `viewer` and `editor` refer to the
#' project that is open in the caller's session. `account = TRUE` means the
#' caller must be signed in, and `rule` names a check on the arguments; the
#' permission model as a whole is described in `R/access.R`.
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

  # Arguments that DataTables sends with every server-side page request.
  dt_args <- list(
    columns = arg_json(optional = TRUE),
    draw    = arg_int(min = 0L, default = 1L),
    start   = arg_int(min = 0L, default = 0L),
    length  = arg_int(min = 1L, max = 1000L, default = 10L),
    search  = arg_json(optional = TRUE),
    order   = arg_json(optional = TRUE) )

  list(

    #__________________________________________________________________________
    # Sessions

    route("POST /api/session/init", "api_init_session", "public", "compute", args = list(
      access_key = arg_string(max = 40L, optional = TRUE) )),

    route("POST /api/session/heartbeat", "api_heartbeat", "session", "fast"),

    route("POST /api/session/abort", "api_abort", "session", "fast"),


    #__________________________________________________________________________
    # Signing in and out. These only exist when the server has accounts.
    # The two GET routes are pages the browser itself goes to, on the way to
    # and from the identity provider (`R/auth-oidc.R`).

    route("GET /auth/login", "auth_login", "public", "fast", modes = "oidc", html = TRUE, args = list(
      return_to = arg_string(max = 100L, default = "/") )),

    route("GET /auth/callback", "auth_callback", "public", "fast", modes = "oidc", html = TRUE, strict = FALSE, args = list(
      code              = arg_string(max = 4000L, optional = TRUE),
      state             = arg_string(max = 200L,  optional = TRUE),
      error             = arg_string(max = 200L,  optional = TRUE),
      error_description = arg_string(max = 2000L, optional = TRUE) )),

    route("POST /api/account/sign_out", "api_sign_out", "session", "fast", modes = "oidc"),

    route("POST /api/account/details", "api_account_details", "session", "fast", account = TRUE, modes = "oidc"),


    #__________________________________________________________________________
    # The open project

    route("POST /api/project/upload", "api_upload_biom", "session", "compute", args = list(
      biom_file = arg_file(),
      inflate   = arg_bool(default = FALSE) )),

    route("POST /api/project/upload_component", "api_upload_component", "viewer", "compute", args = list(
      component      = arg_choice(c("metadata", "taxonomy", "tree")),
      component_file = arg_file() )),

    route("POST /api/project/rarefy", "api_rarefy", "viewer", "compute", supersede = TRUE, args = list(
      depth = arg_int(min = 1L) )),

    route("POST /api/project/save", "api_save", "editor", "compute", args = list(
      title       = arg_string(min = 3L, max = 100L),
      description = arg_html(max = 5000L) )),

    route("POST /api/project/save_as", "api_save_as", "viewer", "compute", args = list(
      title       = arg_string(min = 3L, max = 100L),
      description = arg_html(max = 5000L) )),

    route("POST /api/project/new_key", "api_new_key", "editor", "fast"),

    route("POST /api/project/publish", "api_publish", "editor", "compute", account = TRUE, args = list(
      is_public     = arg_bool(),
      public_key    = arg_string(min = 4L, max = 20L, pattern = public_key_pattern, optional = TRUE),
      collection_id = arg_int(min = 1L, optional = TRUE) )),

    route("POST /api/project/export", "api_export", "viewer", "compute", args = list(
      what       = arg_choice(c("original", "metadata", "taxonomy", "tree", "biom", "alpha", "beta", "taxa", "xlsx")),
      sample_set = arg_choice(c("full", "rare"), default = "full"),
      format     = arg_choice(c("json", "hdf5", "tab"), default = "json"),
      method     = arg_metric("bdiv_distmat", "bdiv", default = "bray"),
      rank       = arg_rank(default = ".otu") )),


    #__________________________________________________________________________
    # The project tree. These act on whichever node is named, so the `tree`
    # rule checks that each node belongs to the caller; `tree_edit` also
    # asks for editing rights on a project node.

    route("POST /api/tree/select", "api_tree_select", "session", "compute", rule = "tree", args = list(
      node_id = arg_node("PG") )),

    route("POST /api/tree/create", "api_tree_create", "session", "fast", rule = "tree", args = list(
      node_id = arg_node("CP", root = TRUE) )),

    route("POST /api/tree/rename", "api_tree_rename", "session", "fast", rule = "tree_edit", args = list(
      node_id = arg_node("CP"),
      text    = arg_string(min = 3L, max = 100L) )),

    route("POST /api/tree/leave", "api_tree_leave", "session", "fast", rule = "tree", args = list(
      node_id = arg_node("P") )),

    route("POST /api/tree/delete", "api_tree_delete", "session", "fast", rule = "tree_edit", args = list(
      node_id = arg_node("CP") )),

    route("POST /api/tree/move", "api_tree_move", "session", "fast", rule = "tree", args = list(
      node_id        = arg_node("CP"),
      parent_node_id = arg_node("C", root = TRUE) )),


    #__________________________________________________________________________
    # Sharing the open project with other users. Only for people who are
    # signed in, so not at all when the server has no accounts. The `grant`
    # rule decides whose access the caller may change, and how.

    route("POST /api/sharing/user_search", "api_sharing_user_search", "session", "fast", account = TRUE, modes = "oidc", args = list(
      query = arg_string(min = 1L, max = 99L, pattern = "^[A-Za-z0-9@_ .\\-]+$") )),

    route("POST /api/sharing/editors", "api_get_editors", "viewer", "fast", account = TRUE, modes = "oidc"),

    route("POST /api/sharing/list", "api_sharing_with", "viewer", "fast", account = TRUE, modes = "oidc"),

    route("POST /api/sharing/update", "api_update_permissions", "viewer", "fast", account = TRUE, modes = "oidc", rule = "grant", args = list(
      user_id     = arg_int(min = 1L),
      permissions = arg_choice(c("none", "view", "edit", "any")) )),


    #__________________________________________________________________________
    # Importing projects from an older atima (`R/legacy.R`). For people with
    # an account: what is imported lands in their project tree. The old
    # email address and password are checked by a worker against a file
    # the administrator registered; `arg_secret()` keeps the password out
    # of logs and errors.

    route("POST /api/legacy/sources", "api_legacy_sources", "session", "fast", account = TRUE),

    route("POST /api/legacy/list", "api_legacy_list", "session", "compute", account = TRUE, args = list(
      source   = arg_string(min = 1L, max = 40L, pattern = "^[a-z0-9]+$"),
      email    = arg_string(min = 3L, max = 255L),
      password = arg_secret(min = 1L, max = 200L) )),

    route("POST /api/legacy/import", "api_legacy_import", "session", "compute", account = TRUE, args = list(
      source   = arg_string(min = 1L, max = 40L, pattern = "^[a-z0-9]+$"),
      email    = arg_string(min = 3L, max = 255L),
      password = arg_secret(min = 1L, max = 200L),
      project  = arg_string(min = 1L, max = 20L, pattern = "^[0-9]+$"),
      inflate  = arg_bool(default = FALSE) )),


    #__________________________________________________________________________
    # Metadata and taxonomy of the open project

    route("POST /api/metadata/table", "api_metadata_dt", "viewer", "compute", supersede = TRUE, args = dt_args),

    route("POST /api/metadata/thead", "api_metadata_thead", "viewer", "compute"),

    route("POST /api/metadata/change_class", "api_metadata_change_class", "viewer", "compute", args = list(
      col_num = arg_int(min = 2L) )),

    route("POST /api/metadata/add_clusters", "api_add_clusters", "viewer", "compute", args = list(
      cluster_fn   = arg_choice(schema_fns("clusters")),
      cluster_args = arg_fn_args("cluster_fn", optional = TRUE),
      name         = arg_string(min = 1L, max = 50L, pattern = "^[A-Za-z][A-Za-z0-9 _\\-]*$") )),

    route("POST /api/taxonomy/table", "api_taxonomy_dt", "viewer", "compute", supersede = TRUE, args = dt_args),

    route("POST /api/taxonomy/thead", "api_taxonomy_thead", "viewer", "compute"),


    #__________________________________________________________________________
    # Plots. The schema says which rbiom functions can be named and what
    # their arguments may be (`R/schema.R`); `plot_args`, `save_args` and
    # `subset_args` are checked against it here, before any worker is used.

    route("POST /api/schema", "api_schema", "public", "fast"),

    route("POST /api/plot", "api_plot", "viewer", "compute", supersede = TRUE, args = list(
      plot_fn     = arg_choice(schema_fns("plot")),
      plot_args   = arg_fn_args("plot_fn"),
      depth       = arg_int(min = 1L),
      save_args   = arg_save_args(default = check_save_args(list())),
      subset_args = arg_subset_args(optional = TRUE),
      attrs       = arg_bool(default = FALSE) )),


    #__________________________________________________________________________
    # BIOM file downloads, fetched by R scripts that have no cookie. The key
    # in the URL is the permission: a project's public or private key, or
    # the session key of an unsaved draft. The rules check that the key
    # exists.

    route("GET /unsaved/:session_key/:file", "download_draft_biom", "public", "compute", rule = "draft_key", args = list(
      session_key = arg_string(min = 1L, max = 40L, pattern = "^[A-Za-z0-9]+$"),
      file        = arg_string(pattern = biom_file_pattern) )),

    route("GET /:access_key/:file", "download_project_biom", "public", "compute", rule = "project_key", args = list(
      access_key = arg_string(min = 4L, max = 40L, pattern = access_key_pattern),
      file       = arg_string(pattern = biom_file_pattern) )),


    #__________________________________________________________________________
    # The single-page app: "/" and "/<project key>" both load index.html.
    # Links to a page pick up parameters on their way round the web
    # ("?utm_source=..."), so these two routes ignore what they do not know.

    route("GET /", "serve_index", "public", "fast", html = TRUE, strict = FALSE, args = list(
      access_key = arg_string(max = 100L, optional = TRUE) )),

    route("GET /:access_key", "serve_index", "public", "fast", html = TRUE, strict = FALSE, args = list(
      access_key = arg_string(max = 100L) ))
  )
}


# A project key in a URL, public or private: letters, digits and inner
# hyphens. (What a new public key may look like is `public_key_pattern`.)
access_key_pattern <- "^[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?$"

# Names a BIOM download may have: <rare|full>.<format>[.<compression>]
biom_file_pattern <- "^(rare|full)\\.(tab|json|hdf5)(\\.gz|\\.bz2)?$"
