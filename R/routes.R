#______________________________________________________________________________
#' The route table: every request atima answers, in one place.
#'
#' See `route()` for the meaning of each field. API routes are POSTs under
#' `/api/<area>/<action>`; their arguments arrive as a JSON object, or as a
#' multipart form when a file is uploaded. `viewer` and `editor` refer to the
#' project that is open in the caller's session. `account = TRUE` means the
#' caller must be signed in, and `rule` names a check on the arguments; the
#' permission model as a whole is described in `R/access.R`. An `admin` route
#' is for administrators, whatever project they have open.
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

    # `referrer` is the page that sent the browser here, if another site
    # did. It is only looked at by usage monitoring, on a shared server.
    route("POST /api/session/init", "api_init_session", "public", "compute", usage = "visit", args = list(
      access_key = arg_string(max = 40L, optional = TRUE),
      referrer   = arg_string(max = 2000L, optional = TRUE) )),

    route("POST /api/session/heartbeat", "api_heartbeat", "session", "fast"),

    route("POST /api/session/abort", "api_abort", "session", "fast"),


    #__________________________________________________________________________
    # Is the server able to work? For whatever watches over it: a container's
    # health check, a load balancer, a monitor. Those send a GET, so this is
    # the one API route that is not a POST. It starts no session and sets no
    # cookie (`R/health.R`).

    route("GET /api/health", "api_health", "public", "fast"),


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

    route("POST /api/project/upload", "api_upload_biom", "session", "compute", usage = "upload", args = list(
      biom_file = arg_file(),
      inflate   = arg_bool(default = FALSE) )),

    route("POST /api/project/upload_component", "api_upload_component", "viewer", "compute", usage = "upload", args = list(
      component      = arg_choice(c("metadata", "taxonomy", "tree")),
      component_file = arg_file() )),

    route("POST /api/project/rarefy", "api_rarefy", "viewer", "compute", usage = "rarefy", supersede = TRUE, args = list(
      depth = arg_int(min = 1L) )),

    route("POST /api/project/save", "api_save", "editor", "compute", usage = "save", args = list(
      title       = arg_string(min = 3L, max = 100L),
      description = arg_html(max = 5000L) )),

    route("POST /api/project/save_as", "api_save_as", "viewer", "compute", usage = "save", args = list(
      title       = arg_string(min = 3L, max = 100L),
      description = arg_html(max = 5000L) )),

    route("POST /api/project/new_key", "api_new_key", "editor", "fast", usage = "share"),

    route("POST /api/project/publish", "api_publish", "editor", "compute", usage = "publish", account = TRUE, args = list(
      is_public     = arg_bool(),
      public_key    = arg_string(min = 4L, max = 20L, pattern = public_key_pattern, optional = TRUE),
      collection_id = arg_int(min = 1L, optional = TRUE) )),

    route("POST /api/project/export", "api_export", "viewer", "compute", usage = "export", args = list(
      what       = arg_choice(c("original", "metadata", "taxonomy", "tree", "biom", "alpha", "beta", "taxa", "xlsx")),
      sample_set = arg_choice(c("full", "rare"), default = "full"),
      format     = arg_choice(c("json", "hdf5", "tab"), default = "json"),
      method     = arg_metric("bdiv_distmat", "bdiv", default = "bray"),
      rank       = arg_rank(default = ".otu") )),


    #__________________________________________________________________________
    # The project tree. These act on whichever node is named, so the `tree`
    # rule checks that each node belongs to the caller; `tree_edit` also
    # asks for editing rights on a project node.

    route("POST /api/tree/select", "api_tree_select", "session", "compute", usage = "open", rule = "tree", args = list(
      node_id = arg_node("PG") )),

    route("POST /api/tree/create", "api_tree_create", "session", "fast", usage = "manage", rule = "tree", args = list(
      node_id = arg_node("CP", root = TRUE) )),

    route("POST /api/tree/rename", "api_tree_rename", "session", "fast", usage = "manage", rule = "tree_edit", args = list(
      node_id = arg_node("CP"),
      text    = arg_string(min = 3L, max = 100L) )),

    route("POST /api/tree/leave", "api_tree_leave", "session", "fast", usage = "manage", rule = "tree", args = list(
      node_id = arg_node("P") )),

    route("POST /api/tree/delete", "api_tree_delete", "session", "fast", usage = "manage", rule = "tree_edit", args = list(
      node_id = arg_node("CP") )),

    # A deleted project is kept for `trash_days`; until then its editors
    # can list and restore it.
    route("POST /api/tree/deleted", "api_tree_deleted", "session", "fast"),

    route("POST /api/tree/restore", "api_tree_restore", "session", "fast", usage = "manage", rule = "tree_restore", args = list(
      node_id = arg_node("P") )),

    route("POST /api/tree/move", "api_tree_move", "session", "fast", usage = "manage", rule = "tree", args = list(
      node_id        = arg_node("CP"),
      parent_node_id = arg_node("C", root = TRUE) )),


    #__________________________________________________________________________
    # The public tree: the collections (folders) that public projects are
    # listed under, which belong to nobody. Administrators arrange it. The
    # `public_tree` rule checks that each node named is a public collection
    # or a public project, so nothing of a user's own tree can be reached
    # through these routes; and the routes above never reach a public
    # collection, because it is nobody's.

    route("POST /api/public/create", "api_public_create", "admin", "fast", rule = "public_tree", args = list(
      parent_node_id = arg_node("C", root = TRUE),
      text           = arg_string(min = 3L, max = 100L) )),

    route("POST /api/public/rename", "api_public_rename", "admin", "fast", rule = "public_tree", args = list(
      node_id = arg_node("C"),
      text    = arg_string(min = 3L, max = 100L) )),

    route("POST /api/public/delete", "api_public_delete", "admin", "fast", rule = "public_tree", args = list(
      node_id = arg_node("C") )),

    route("POST /api/public/move", "api_public_move", "admin", "fast", rule = "public_tree", args = list(
      node_id        = arg_node("CG"),
      parent_node_id = arg_node("C", root = TRUE) )),


    #__________________________________________________________________________
    # Sharing the open project with other users. Only for people who are
    # signed in, so not at all when the server has no accounts. The `grant`
    # rule decides whose access the caller may change, and how.

    route("POST /api/sharing/user_search", "api_sharing_user_search", "session", "fast", account = TRUE, modes = "oidc", args = list(
      query = arg_string(min = 1L, max = 99L, pattern = "^[A-Za-z0-9@_ .\\-]+$") )),

    route("POST /api/sharing/editors", "api_get_editors", "viewer", "fast", account = TRUE, modes = "oidc"),

    route("POST /api/sharing/list", "api_sharing_with", "viewer", "fast", account = TRUE, modes = "oidc"),

    route("POST /api/sharing/update", "api_update_permissions", "viewer", "fast", usage = "share", account = TRUE, modes = "oidc", rule = "grant", args = list(
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

    # An import runs in the background: `start` hands the server a list
    # of projects and returns, `status` says how far it has come.
    route("POST /api/legacy/start", "api_legacy_start", "session", "compute", usage = "import", account = TRUE, args = list(
      source   = arg_string(min = 1L, max = 40L, pattern = "^[a-z0-9]+$"),
      email    = arg_string(min = 3L, max = 255L),
      password = arg_secret(min = 1L, max = 200L),
      projects = arg_strings(pattern = "^[0-9]{1,20}$", max_n = 2000L),
      inflate  = arg_bool(default = FALSE) )),

    route("POST /api/legacy/status", "api_legacy_status", "session", "fast", account = TRUE, args = list(
      tree = arg_bool(default = FALSE) )),

    route("POST /api/legacy/cancel", "api_legacy_cancel", "session", "fast", account = TRUE),


    #__________________________________________________________________________
    # Metadata and taxonomy of the open project

    route("POST /api/metadata/table", "api_metadata_dt", "viewer", "compute", usage = "table", supersede = TRUE, args = dt_args),

    route("POST /api/metadata/thead", "api_metadata_thead", "viewer", "compute"),

    route("POST /api/metadata/change_class", "api_metadata_change_class", "viewer", "compute", usage = "manage", args = list(
      col_num = arg_int(min = 2L) )),

    route("POST /api/metadata/add_clusters", "api_add_clusters", "viewer", "compute", usage = "clusters", usage_fn = "cluster_fn", args = list(
      cluster_fn   = arg_choice(schema_fns("clusters")),
      cluster_args = arg_fn_args("cluster_fn", optional = TRUE),
      name         = arg_string(min = 1L, max = 50L, pattern = "^[A-Za-z][A-Za-z0-9 _\\-]*$") )),

    route("POST /api/taxonomy/table", "api_taxonomy_dt", "viewer", "compute", usage = "table", supersede = TRUE, args = dt_args),

    route("POST /api/taxonomy/thead", "api_taxonomy_thead", "viewer", "compute"),


    #__________________________________________________________________________
    # Plots. The schema says which rbiom functions can be named and what
    # their arguments may be (`R/schema.R`); `plot_args`, `save_args` and
    # `subset_args` are checked against it here, before any worker is used.

    route("POST /api/schema", "api_schema", "public", "fast"),

    route("POST /api/plot", "api_plot", "viewer", "compute", usage = "plot", usage_fn = "plot_fn", supersede = TRUE, args = list(
      plot_fn     = arg_choice(schema_fns("plot")),
      plot_args   = arg_fn_args("plot_fn"),
      depth       = arg_int(min = 1L),
      save_args   = arg_save_args(default = check_save_args(list())),
      subset_args = arg_subset_args(optional = TRUE),
      attrs       = arg_bool(default = FALSE) )),


    #__________________________________________________________________________
    # The Model Context Protocol endpoint, through which AI apps use atima
    # as a set of tools (`R/mcp.R`). It takes JSON-RPC messages, so its
    # handler gets the request as it came. The route is `public` because
    # there is no cookie or tab session; who the caller is, and what each
    # tool needs, is decided per tool call (`tool_call()` in
    # `R/mcp-tools.R`). On a server with accounts the caller is the user of
    # the bearer token the request carries (`R/oauth.R`).

    route("POST /mcp", "mcp_post", "public", "compute", raw = TRUE, args = list(
      body    = arg_body(),
      headers = arg_headers() )),

    route("GET /mcp", "mcp_get", "public", "fast"),


    #__________________________________________________________________________
    # Signing in for AI apps (`R/oauth.R`): on a server with accounts, atima
    # is the OAuth authorization server that issues the tokens `/mcp` asks
    # for. The first three are documents apps read to find their way. The
    # two `/oauth` pages are for a person's browser; who that person is
    # comes from the auth cookie, which the handlers check themselves,
    # since a browser on these pages has no tab session. The token and
    # revocation endpoints are called by the apps and take no cookie:
    # what proves the caller is the code, PKCE verifier or token it sends.

    route("GET /.well-known/oauth-protected-resource", "oauth_protected_resource", "public", "fast", modes = "oidc"),

    route("GET /.well-known/oauth-protected-resource/mcp", "oauth_protected_resource", "public", "fast", modes = "oidc"),

    route("GET /.well-known/oauth-authorization-server", "oauth_server_metadata", "public", "fast", modes = "oidc"),

    route("GET /oauth/authorize", "oauth_authorize", "public", "fast", modes = "oidc", html = TRUE, strict = FALSE, args = list(
      response_type         = arg_string(max = 40L,   optional = TRUE),
      client_id             = arg_string(max = 300L,  optional = TRUE),
      redirect_uri          = arg_string(max = 500L,  optional = TRUE),
      code_challenge        = arg_string(max = 200L,  optional = TRUE),
      code_challenge_method = arg_string(max = 20L,   optional = TRUE),
      state                 = arg_string(max = 1000L, optional = TRUE, trim = FALSE),
      scope                 = arg_string(max = 200L,  optional = TRUE),
      resource              = arg_string(max = 500L,  optional = TRUE),
      request               = arg_string(max = 43L,   optional = TRUE, pattern = "^[A-Za-z0-9]{43}$") )),

    route("POST /oauth/approve", "oauth_approve", "public", "fast", modes = "oidc", html = TRUE, args = list(
      request  = arg_string(max = 43L, pattern = "^[A-Za-z0-9]{43}$"),
      csrf     = arg_secret(min = 43L, max = 43L),
      decision = arg_choice(c("connect", "cancel")),
      access   = arg_choice(c("read", "write"), default = "read") )),

    route("POST /oauth/token", "oauth_token", "public", "fast", modes = "oidc", strict = FALSE, args = list(
      grant_type    = arg_string(max = 40L,  optional = TRUE),
      client_id     = arg_string(max = 300L, optional = TRUE),
      code          = arg_secret(max = 200L, optional = TRUE),
      redirect_uri  = arg_string(max = 500L, optional = TRUE),
      code_verifier = arg_secret(max = 200L, optional = TRUE),
      refresh_token = arg_secret(max = 200L, optional = TRUE),
      resource      = arg_string(max = 500L, optional = TRUE),
      scope         = arg_string(max = 200L, optional = TRUE) )),

    route("POST /oauth/revoke", "oauth_revoke", "public", "fast", modes = "oidc", strict = FALSE, args = list(
      token           = arg_secret(max = 200L, optional = TRUE),
      token_type_hint = arg_string(max = 40L,  optional = TRUE) )),


    #__________________________________________________________________________
    # What AI apps have been let in, and what they did (`R/apps.R`). The
    # record of changes exists on a server without accounts too; the list
    # of connected apps is empty there, since nothing needs approving. The
    # `app_grant` rule checks that a connection named is the caller's own.

    route("POST /api/apps/list", "api_apps_list", "session", "fast", account = TRUE),

    route("POST /api/apps/disconnect", "api_apps_disconnect", "session", "fast", account = TRUE, modes = "oidc", rule = "app_grant", args = list(
      grant_id = arg_int(min = 1L, optional = TRUE) )),


    #__________________________________________________________________________
    # What use of the server has been recorded (`R/usage.R`), for its
    # administrators: the numbers behind the "Usage" page, for a range of
    # days. Only a server with accounts records its use, so the route does
    # not exist on a local install.

    route("POST /api/usage/data", "api_usage_data", "admin", "fast", modes = "oidc", args = list(
      from = arg_string(pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", optional = TRUE),
      to   = arg_string(pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", optional = TRUE) )),


    #__________________________________________________________________________
    # A file sent for a tool call (`R/mcp-upload.R`). An AI app that is
    # allowed to change data asks for a ticket with the `upload_file` tool
    # and is given a command that sends the file here. The ticket is the
    # permission: it works once, for a quarter of an hour, for the person
    # and the purpose it was made for (the `upload_ticket` rule).

    route("POST /api/upload", "api_upload_ticket", "public", "compute", usage = "upload", rule = "upload_ticket", args = list(
      ticket = arg_secret(min = 20L, max = 100L),
      file   = arg_file() )),


    #__________________________________________________________________________
    # BIOM file downloads, fetched by R scripts that have no cookie. The key
    # in the URL is the permission: a project's public or private key, or
    # the session key of an unsaved draft. The rules check that the key
    # exists.

    route("GET /unsaved/:session_key/:file", "download_draft_biom", "public", "compute", usage = "download", rule = "draft_key", args = list(
      session_key = arg_string(min = 1L, max = 40L, pattern = "^[A-Za-z0-9]+$"),
      file        = arg_string(pattern = biom_file_pattern) )),

    route("GET /:access_key/:file", "download_project_biom", "public", "compute", usage = "download", rule = "project_key", args = list(
      access_key = arg_string(min = 4L, max = 40L, pattern = access_key_pattern),
      file       = arg_string(pattern = biom_file_pattern) )),


    #__________________________________________________________________________
    # The single-page app: "/" and "/<project key>" both load index.html.
    # Links to a page pick up parameters on their way round the web
    # ("?utm_source=..."), so these two routes ignore what they do not know.

    route("GET /", "serve_index", "public", "fast", usage = "page", html = TRUE, strict = FALSE, args = list(
      access_key = arg_string(max = 100L, optional = TRUE) )),

    route("GET /:access_key", "serve_index", "public", "fast", usage = "page", html = TRUE, strict = FALSE, args = list(
      access_key = arg_string(max = 100L) ))
  )
}


# A project key in a URL, public or private: letters, digits and inner
# hyphens. (What a new public key may look like is `public_key_pattern`.)
access_key_pattern <- "^[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?$"

# Names a BIOM download may have: <rare|full>.<format>[.<compression>]
biom_file_pattern <- "^(rare|full)\\.(tab|json|hdf5)(\\.gz|\\.bz2)?$"
