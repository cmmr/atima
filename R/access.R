#______________________________________________________________________________
# Who may do what. Every permission rule in atima is in this file.
#
# The router applies them (`check_permission()` and `check_rule()` in
# `R/router.R`); handlers do not check anything themselves. The one caller
# outside the router is `api_init_session()`, which uses `open_by_key()` to
# decide which project a new session starts with.
#
# The model:
#
#   * A project has a private key (`access_key`: random, always present) and
#     may have a public key (`public_key`: short and readable). It is public
#     exactly when it has a public key.
#   * Anyone can read a public project.
#   * Whoever knows a project's private key can read it. A browser that
#     opens a project by its private key is given a lasting view grant.
#     Taking away someone's grant does not make them forget the key; an
#     editor who wants to shut out everyone who had it gives the project a
#     new one (`/api/project/new_key`).
#   * A grant (a row of `permissions`) makes its user a viewer or an editor
#     of the project. Editors can change the project and anyone's grant.
#     Viewers can pass on view access and take back what they passed on.
#   * A guest is a visitor who has not signed in. Guests can upload and save,
#     but cannot be granted anything by name, grant anything, or publish.
#   * Administrators can change public projects, and arrange the public
#     tree: its collections, and which collection a public project is
#     listed under. They have no access to other people's private projects.
#
# A route asks for a level (`public`, `session`, `viewer`, `editor`,
# `admin`), may add `account = TRUE` (the caller must be signed in), and may
# name one of the rules in `access_rules`, which looks at the request's
# arguments.
#
# A tool called through the MCP endpoint (`R/mcp-tools.R`) has no session
# and no open project: it names its project by key in every call.
# `caller_project()` applies the same model to that: the caller needs a
# grant on the project, or the project must be public. Knowing a private
# key is not enough there, and using one never creates a grant, so that an
# AI app cannot quietly add projects to someone's tree.
#______________________________________________________________________________


#______________________________________________________________________________
#' What a user may do with a project.
#'
#' @param user_id  May be `NULL` for a visitor with no account.
#' @return `"editor"`, `"viewer"` or `"none"`.
#' @noRd
project_access <- function (DB, project_id, user_id = NULL) {

  if (is.null(project_id) || is.na(project_id)) return ("none")

  sql <- "SELECT COUNT(*) AS n, COUNT(public_key) AS n_public FROM projects WHERE project_id = ?"
  res <- db_query(DB, sql, "PAcc1", list(project_id))
  if (res[['n']] == 0) return ("none")

  is_public <- res[['n_public']] > 0
  is_editor <- NULL
  is_admin  <- FALSE

  if (!is.null(user_id)) {
    sql <- "SELECT is_editor FROM permissions WHERE project_id = ? AND user_id = ?"
    is_editor <- db_query(DB, sql, "PAcc2", list(project_id, user_id))

    sql <- "SELECT is_admin FROM users WHERE user_id = ?"
    is_admin <- isTRUE(db_query(DB, sql, "PAcc3", list(user_id)))
  }

  if (isTRUE(is_editor))        return ("editor")
  if (is_public && is_admin)    return ("editor")
  if (!is.null(is_editor))      return ("viewer")
  if (is_public)                return ("viewer")

  return ("none")
}


#______________________________________________________________________________
#' Find the project a key belongs to.
#'
#' @param key  A private or public project key, as it appears in a URL.
#' @return `list(project_id, private)`, where `private` says whether `key` is
#'         the project's private key; or `NULL` if no project has that key.
#' @noRd
key_project <- function (DB, key) {

  if (!is_scalar_character(key) || is.na(key) || !nzchar(key)) return (NULL)

  sql <- "SELECT project_id, access_key FROM projects WHERE access_key = ? OR public_key = ?"
  res <- db_query(DB, sql, "KProj1", list(key, key), simplify = FALSE)
  if (nrow(res) != 1) return (NULL)

  list(
    project_id = res[['project_id']],
    private    = identical(res[['access_key']], key) )
}


#______________________________________________________________________________
#' The project a tool call names, if its caller may use it that way.
#'
#' @param user_id  The caller.
#' @param key      A private or public project key.
#' @param level    What the tool asks for: `"editor"` to change the project;
#'                 anything else needs the caller to be able to read it.
#' @return The project and the caller's access to it, in the shape of a
#'         session (`resume_session()`) with no session id or key:
#'         `user_id`, `project_id`, `access`, `is_editor`, `is_public`,
#'         `project_key` and the columns of `projects`. Stops with a 404 if
#'         there is no such project or the caller cannot read it (the same
#'         answer for both, so that keys cannot be probed), and a 403 if
#'         they can read it but not change it.
#' @noRd
caller_project <- function (DB, user_id, key, level = "viewer") {

  found  <- key_project(DB, key)
  access <- if (is.null(found)) "none" else project_access(DB, found[['project_id']], user_id)

  if (identical(access, "none"))
    stop_not_found("There is no project with that key, or you do not have access to it.")

  if (identical(level, "editor") && !identical(access, "editor"))
    stop_forbidden("You do not have permission to change this project.")

  sql     <- "SELECT * FROM projects WHERE project_id = ?"
  project <- db_query(DB, sql, "CProj1", list(found[['project_id']]), req1 = TRUE)

  is_public <- !is.na(project[['public_key']])

  c(
    list(
      user_id     = user_id,
      access      = access,
      is_editor   = identical(access, "editor"),
      is_public   = is_public,
      # The key that is safe to show: a private key is a share link.
      project_key = if (is_public) project[['public_key']] else project[['access_key']] ),
    project )
}


#______________________________________________________________________________
#' Open a project by the key in a page's URL.
#'
#' A private key is a share link: a user who arrives with one and has no
#' access to the project yet is given a view grant, so the project stays in
#' their tree.
#'
#' @return The project_id, or `NULL` if no project has that key.
#' @noRd
open_by_key <- function (DB, key, user_id) {

  found <- key_project(DB, key)
  if (is.null(found)) return (NULL)

  project_id <- found[['project_id']]

  if (found[['private']] && identical(project_access(DB, project_id, user_id), "none"))
    update_permissions(DB, user_id, project_id, "view")

  project_id
}


#______________________________________________________________________________
#' The rules a route can name. Each is called as `rule(REQ, args)` with the
#' validated arguments, and stops with a 403 or 404 if the request is not
#' allowed.
#' @noRd
access_rules <- list(

  # Tree nodes named in the request belong to the caller (or, for a public
  # project node, are public).
  tree = function (REQ, args) check_nodes(REQ, args, editor = FALSE),

  # The same, and a project node needs editing rights.
  tree_edit = function (REQ, args) check_nodes(REQ, args, editor = TRUE),

  # The public tree, which administrators arrange: the nodes named are
  # public collections and public projects. (That the caller is an
  # administrator is the route's level, `admin`.)
  public_tree = function (REQ, args) check_public_nodes(REQ, args),

  # Changing somebody's grant on the open project.
  grant = function (REQ, args) {
    check_grant(
      DB              = REQ[['DB']],
      user_id         = args[['user_id']],
      grantor_user_id = REQ[['SESSION']][['user_id']],
      project_id      = REQ[['SESSION']][['project_id']],
      permissions     = args[['permissions']] )
  },

  # A download by project key: the key is the permission.
  project_key = function (REQ, args) {
    if (is.null(key_project(REQ[['DB']], args[['access_key']])))
      stop_not_found("Project not found.")
  },

  # A download of a session's working copy: the session key is the
  # permission.
  draft_key = function (REQ, args) {
    sql <- "SELECT COUNT(*) FROM sessions WHERE session_key = ? AND logout_utc IS NULL AND draft_id IS NOT NULL"
    if (db_query(REQ[['DB']], sql, "DKey1", list(args[['session_key']])) != 1)
      stop_not_found("Project not found.")
  }
)


#______________________________________________________________________________
#' Check every tree node among a request's arguments.
#'
#' @param editor  Must the caller be an editor of a project node?
#' @noRd
check_nodes <- function (REQ, args, editor = FALSE) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]
  specs   <- REQ[['ROUTE']][['args']]

  for (key in names(args)) {

    if (!identical(specs[[key]][['type']], "node")) next

    node_id <- args[[key]]
    kind    <- substr(node_id, 1, 1)
    number  <- node_number(node_id)

    if (kind == "C") {

      sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id = ?"
      if (db_query(DB, sql, "CNode1", list(number, user_id)) == 0)
        stop_forbidden("That collection is not yours. Please reload the page.")

    } else if (kind == "P") {

      sql       <- "SELECT is_editor FROM permissions WHERE permission_id = ? AND user_id = ?"
      is_editor <- db_query(DB, sql, "CNode2", list(number, user_id))

      if (is.null(is_editor))
        stop_forbidden("That project is not in your collections. Please reload the page.")

      if (editor && !isTRUE(is_editor))
        stop_forbidden("You do not have permission to change this project.")

    } else if (kind == "G") {

      sql <- "SELECT COUNT(*) FROM projects WHERE project_id = ? AND public_key IS NOT NULL"
      if (db_query(DB, sql, "CNode3", list(number)) == 0)
        stop_forbidden("You do not have access to that project.")
    }
  }

  invisible(TRUE)
}


#______________________________________________________________________________
#' Check that every tree node among a request's arguments is part of the
#' public tree: a collection that belongs to nobody, or a public project.
#' The top of the tree (`"#"`) always is.
#' @noRd
check_public_nodes <- function (REQ, args) {

  DB    <- REQ[['DB']]
  specs <- REQ[['ROUTE']][['args']]

  for (key in names(args)) {

    if (!identical(specs[[key]][['type']], "node")) next

    node_id <- args[[key]]
    kind    <- substr(node_id, 1, 1)
    number  <- node_number(node_id)

    if (kind == "C") {

      sql <- "SELECT COUNT(*) FROM collections WHERE collection_id = ? AND user_id IS NULL"
      if (db_query(DB, sql, "PNode1", list(number)) == 0)
        stop_forbidden("That is not a public collection. Please reload the page.")

    } else if (kind == "G") {

      sql <- "SELECT COUNT(*) FROM projects WHERE project_id = ? AND public_key IS NOT NULL"
      if (db_query(DB, sql, "PNode2", list(number)) == 0)
        stop_forbidden("That is not a public project. Please reload the page.")

    } else if (kind != "#") {

      stop_forbidden("That is not part of the public project tree.")
    }
  }

  invisible(TRUE)
}


#______________________________________________________________________________
#' Stop unless one user may change another user's grant on a project.
#'
#' @param user_id          Whose grant is to change.
#' @param grantor_user_id  Who is asking. The router has already checked that
#'                         they are signed in and can read the project.
#' @param permissions      `"none"` (revoke), `"view"`, `"edit"`, or `"any"`
#'                         (make sure they can at least view).
#' @noRd
check_grant <- function (DB, user_id, grantor_user_id, project_id, permissions) {

  stopifnot(is_scalar_integer(user_id))
  stopifnot(is_scalar_integer(grantor_user_id))
  stopifnot(is_scalar_integer(project_id))
  stopifnot(is_one_of(permissions, c("none", "view", "edit", "any")))

  level <- function (uid) {
    sql <- "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?"
    res <- db_query(DB, sql, "CGran1", list(uid, project_id))
    if (is.null(res)) "none" else if (res) "edit" else "view"
  }


  #________________________________________________________
  # Grants go to people with accounts.
  #________________________________________________________
  sql <- "SELECT is_guest FROM users WHERE user_id = ?"
  if (!isFALSE(db_query(DB, sql, "CGran2", list(user_id))))
    stop_user("Cannot grant permissions to a guest account.")


  #________________________________________________________
  # Everyone can already view a public project.
  #________________________________________________________
  uperm <- level(user_id)

  if (permissions %in% c("view", "any") && uperm == "none") {
    sql <- "SELECT COUNT(*) FROM projects WHERE project_id = ? AND public_key IS NOT NULL"
    if (db_query(DB, sql, "CGran3", list(project_id)) > 0)
      stop_user("Public projects are already viewable by everyone.")
  }


  #________________________________________________________
  # Editors (and, on a public project, administrators) may
  # do anything except leave the project with no editor.
  #________________________________________________________
  if (identical(project_access(DB, project_id, grantor_user_id), "editor")) {

    # An administrator edits a public project by office, not by grant, and
    # may not turn that into a grant of their own, which would outlast the
    # project being public.
    if (identical(user_id, grantor_user_id) && level(grantor_user_id) == "none")
      stop_forbidden("Administrators cannot grant themselves access to a project.")

    if (uperm == "edit" && permissions %in% c("none", "view")) {
      sql <- "SELECT COUNT(*) FROM permissions WHERE project_id = ? AND is_editor = 1"
      if (db_query(DB, sql, "CGran4", list(project_id)) <= 1)
        stop_user("A project must keep at least one editor.")
    }

    return (invisible(TRUE))
  }


  #________________________________________________________
  # Viewers may pass on view access, and take back what
  # they themselves passed on.
  #________________________________________________________
  if (level(grantor_user_id) != "view")
    stop_forbidden("You do not have granting permissions.")

  if (permissions == "edit")
    stop_forbidden("Insufficient rights to grant editor permissions.")

  if (uperm == "none") return (invisible(TRUE))

  if (uperm == "edit")
    stop_forbidden("Insufficient rights to modify an editor's permissions.")

  if (permissions %in% c("view", "any"))
    stop_user("User already has view permissions.")

  sql <- "SELECT grantor_user_id FROM permissions WHERE user_id = ? AND project_id = ?"
  if (!identical(db_query(DB, sql, "CGran5", list(user_id, project_id)), grantor_user_id))
    stop_forbidden("Action not allowed.")

  invisible(TRUE)
}
