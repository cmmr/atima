#______________________________________________________________________________
# The tools that change data: what an AI app can do to a project, beyond
# reading it and computing from it (`R/mcp-tools.R`).
#
# They do what a person can do in the browser, with the browser's
# permissions, and they reuse the functions behind the browser's routes
# (`update_permissions()`, `set_public()`, `trash_project()`,
# `new_access_key()`, the `work_*()` functions), so that there is one set
# of rules. Two things differ, because a tool call has no browser tab:
#
#   * There is no working copy. The browser changes a draft and saves it
#     later; a tool changes the saved project in the one call, and says in
#     its result exactly what changed.
#   * The tools that expose data or cannot be undone take `confirm`. Without
#     `confirm: true` they change nothing and describe what would happen
#     (`unconfirmed()`).
#
# A handler here returns, besides `data`, a `change`: one sentence for the
# record of changes, which `tool_call()` writes. A handler that changed
# nothing returns no `change`. Uploads are in `R/mcp-upload.R`.
#______________________________________________________________________________


#______________________________________________________________________________
#' The declarations of the tools that change data, and of the three that
#' only read but exist to serve them.
#'
#' @param project,fn_args,samples  The argument declarations these tools
#'                 share with the reading tools (`mcp_tool_table()`).
#' @param clusters  The names of rbiom's clustering functions.
#' @return A list of `tool` objects.
#' @noRd
mcp_write_tools <- function (project, fn_args, samples, clusters) {

  labels <- paste0(
    clusters, " (", vapply(clusters, function (fn) schema_functions[[fn]][['label']], character(1)), ")", collapse = "; " )

  confirm <- tool_arg(
    spec        = arg_bool(default = FALSE),
    description = paste(
      "Leave this out first: the tool then changes nothing and says what would happen.",
      "Send true only after the person you are working for has been told that and has agreed." ),
    json        = list(type = "boolean", default = FALSE) )

  title <- function (optional) tool_arg(
    spec        = arg_string(min = 3L, max = 100L, optional = optional),
    description = "The project's title, 3 to 100 characters.",
    json        = list(type = "string", minLength = 3L, maxLength = 100L) )

  description <- tool_arg(
    spec        = arg_html(max = 5000L, optional = TRUE),
    description = "The project's description: plain text, or simple HTML (paragraphs, lists, emphasis, links).",
    json        = list(type = "string", maxLength = 5000L) )

  list(

    tool(
      name        = "upload_project",
      title       = "Upload a file as a new project",
      description = paste(
        "Start the upload of a file as a new project of the caller's: a BIOM file (JSON or HDF5), a QIIME 2 feature",
        "table (.qza), a mothur .shared file, or a table of counts as tab- or comma-separated text (taxa in rows,",
        "samples in columns, optionally a `taxonomy` column). A file that cannot be read is refused with the reason.",
        "A tool call cannot carry a file, so this returns a command that sends the file from the computer it is on",
        "to this server, with a ticket that works once and for 15 minutes. Run the command if you can run commands,",
        "or give it to the person to run; then call upload_status to learn the new project's key.",
        "This server never fetches a file from an address." ),
      permission  = "session",
      read_only   = FALSE,
      args        = list(
        title   = title(optional = TRUE),
        inflate = tool_arg(
          spec        = arg_bool(default = FALSE),
          description = paste(
            "Only after an upload was refused because its counts are not whole numbers, and the person has agreed:",
            "scale each sample up to whole numbers. The refusal explains what that does to the data." ),
          json        = list(type = "boolean", default = FALSE) ))),

    tool(
      name        = "upload_component",
      title       = "Replace a project's metadata, taxonomy or tree",
      description = paste(
        "Start the upload of a file that replaces one part of a project: its sample metadata (a table with one row",
        "per sample, as CSV or tab-separated text), its taxonomy (a table with one row per taxon, or a QIIME 2",
        "taxonomy .qza) or its phylogenetic tree (Newick, or a QIIME 2 phylogeny .qza). The part is replaced as a",
        "whole. Samples the new metadata does not list, and taxa the new taxonomy does not list, leave the project;",
        "a tree must have a tip for every taxon. The result says what was dropped, or why the file was refused.",
        "Returns a command that sends the file, as upload_project does; call upload_status afterwards." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      args        = list(
        project   = project,
        component = tool_arg(
          spec        = arg_choice(c("metadata", "taxonomy", "tree")),
          description = "The part of the project to replace.",
          json        = list(type = "string", enum = list("metadata", "taxonomy", "tree")) ))),

    tool(
      name        = "upload_status",
      title       = "See what became of an upload",
      description = paste(
        "Say whether the file for an upload has arrived and what became of it: the new project's key, or what",
        "changed in the project, or why the file was refused." ),
      permission  = "session",
      scope       = "write",
      args        = list(
        upload = tool_arg(
          spec        = arg_int(min = 1L),
          description = "The upload's number, as upload_project or upload_component gave it.",
          json        = list(type = "integer", minimum = 1L) ))),

    tool(
      name        = "edit_project",
      title       = "Change a project's title, description or depth",
      description = paste(
        "Change a project's title, its description, or the rarefaction depth it is saved with (the depth that the",
        "other tools and the web interface use when none is given). Give only what is to change. The result says",
        "what was changed, with the values before and after." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      args        = list(
        project     = project,
        title       = title(optional = TRUE),
        description = description,
        depth       = tool_arg(
          spec        = arg_int(min = 1L, optional = TRUE),
          description = "The rarefaction depth to save the project with. describe_project lists the depths that make sense.",
          json        = list(type = "integer", minimum = 1L) ))),

    tool(
      name        = "add_clusters",
      title       = "Add clusters of samples as a metadata field",
      description = paste0(
        "Group a project's samples into clusters and add the result to its metadata as a new categorical field",
        " (\"Cluster 1\", \"Cluster 2\", ...), which run_stats and make_plot can then compare, color and facet by.",
        " Functions: ", labels, ". describe_function gives their arguments. Samples that rarefying leaves out",
        " are in no cluster." ),
      permission  = "editor",
      read_only   = FALSE,
      args        = list(
        project    = project,
        `function` = tool_arg(
          spec        = arg_choice(clusters),
          description = "The rbiom clustering function to run.",
          json        = list(type = "string", enum = as.list(clusters)) ),
        args       = fn_args,
        name       = tool_arg(
          spec        = arg_string(min = 1L, max = 50L, pattern = "^[A-Za-z][A-Za-z0-9 _\\-]*$"),
          description = "The new field's name: a letter, then letters, digits, spaces, hyphens or underscores. It must not exist yet.",
          json        = list(type = "string", minLength = 1L, maxLength = 50L) ))),

    tool(
      name        = "set_field_type",
      title       = "Make a metadata field numeric or categorical",
      description = paste(
        "Change how a metadata field is read: as numbers (for correlations and ranges) or as categories (for",
        "groups). A field can only become numeric if all its values are numbers. describe_project shows each",
        "field's current type." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      args        = list(
        project = project,
        field   = tool_arg(
          spec        = arg_string(min = 1L, max = 200L),
          description = "The field's name, as describe_project spells it.",
          json        = list(type = "string") ),
        type    = tool_arg(
          spec        = arg_choice(c("numeric", "categorical")),
          description = "What the field is to be.",
          json        = list(type = "string", enum = list("numeric", "categorical")) ))),

    tool(
      name        = "set_level_order",
      title       = "Put a categorical field's values in order",
      description = paste(
        "Set the order of a categorical metadata field's values (its levels), for example a control group first or",
        "time points in time order. Every figure follows it: the groups along an axis, in a legend, in facets.",
        "List the values in the order wanted; values left out follow, in the order they had. describe_project",
        "lists each field's values in their current order. A numeric field must be made categorical first",
        "(set_field_type)." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      args        = list(
        project = project,
        field   = tool_arg(
          spec        = arg_string(min = 1L, max = 200L, trim = FALSE),
          description = "The field's name, as describe_project spells it.",
          json        = list(type = "string") ),
        levels  = tool_arg(
          spec        = arg_strings(pattern = "^(?s).{0,500}$", max_n = 1000L),
          description = "The field's values in the order wanted, spelled as describe_project lists them.",
          json        = list(type = "array", items = list(type = "string"), minItems = 1L, maxItems = 1000L) ))),

    tool(
      name        = "set_group_colors",
      title       = "Give the groups of a categorical field their colors",
      description = paste(
        "Give the groups (values) of a categorical metadata field colors of their own, kept with the project, for",
        "example Control gray and Treated red. Every figure colored by that field uses them, unless the figure's own",
        "`colors` argument is given; the R code make_plot returns has them too. Groups left out keep the color they",
        "have; groups with none get the color-blind-friendly defaults. `reset: true` removes the field's colors first",
        "(alone, it puts every group back to the defaults). describe_project lists the colors set. A numeric field",
        "must be made categorical first (set_field_type)." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      args        = list(
        project = project,
        field   = tool_arg(
          spec        = arg_string(min = 1L, max = 200L, trim = FALSE),
          description = "The field's name, as describe_project spells it.",
          json        = list(type = "string") ),
        colors  = tool_arg(
          spec        = arg_colors(optional = TRUE),
          description = paste(
            "The colors, by group: each group spelled as describe_project lists it, each color a hex code",
            "(\"#1B9E77\") or one of R's color names (\"steelblue\")." ),
          json        = list(type = "object", additionalProperties = list(type = "string"), maxProperties = colors_max_n) ),
        reset   = tool_arg(
          spec        = arg_bool(default = FALSE),
          description = "Remove the colors the field's groups have before giving the ones in `colors`.",
          json        = list(type = "boolean", default = FALSE) ))),

    tool(
      name        = "copy_project",
      title       = "Save a copy of a project",
      description = paste(
        "Save a copy of a project as a new private project of the caller's, with a title of its own; with",
        "`samples`, a copy that holds only some of the samples. The original is not changed. The result gives the",
        "new project's key." ),
      permission  = "viewer",
      read_only   = FALSE,
      args        = list(
        project     = project,
        title       = title(optional = FALSE),
        description = description,
        samples     = samples )),

    tool(
      name        = "find_users",
      title       = "Find a person to share with",
      description = paste(
        "Search the people who have signed in to this server, by name, affiliation or email address, to find the",
        "one a project is to be shared with. Returns up to six closest matches, each with a number for",
        "share_project, a name, an affiliation, and an email address with most of it hidden or an ORCID iD.",
        "The closest matches are returned even when none is the person meant: show the person you are working for",
        "who was found, and let them choose." ),
      permission  = "session",
      scope       = "write",
      modes       = "oidc",
      open_world  = TRUE,
      args        = list(
        query = tool_arg(
          spec        = arg_string(min = 1L, max = 99L, pattern = "^[A-Za-z0-9@_ .\\-]+$"),
          description = "A name, part of one, an affiliation or an email address. Letters, digits, spaces and @ . - _ only.",
          json        = list(type = "string", minLength = 1L, maxLength = 99L) ))),

    tool(
      name        = "list_access",
      title       = "List who a project is shared with",
      description = paste(
        "List the people a project has been shared with by name, and whether each can view or edit it. For a public",
        "project, which everyone can view, only its editors are listed." ),
      permission  = "viewer",
      scope       = "write",
      modes       = "oidc",
      args        = list(project = project) ),

    tool(
      name        = "share_project",
      title       = "Give or take away a person's access",
      description = paste(
        "Give a person who has signed in to this server access to a project (`view` or `edit`), change the access",
        "they have, or take it away (`none`). Someone who can edit a project can change and delete it, and share",
        "and publish it. Find the person's number with find_users or list_access. Takes `confirm`." ),
      permission  = "viewer",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      open_world  = TRUE,
      rule        = "share",
      modes       = "oidc",
      args        = list(
        project = project,
        user_id = tool_arg(
          spec        = arg_int(min = 1L),
          description = "The person's number, as find_users or list_access gives it.",
          json        = list(type = "integer", minimum = 1L) ),
        access  = tool_arg(
          spec        = arg_choice(c("view", "edit", "none")),
          description = "The access the person is to have from now on.",
          json        = list(type = "string", enum = list("view", "edit", "none")) ),
        confirm = confirm )),

    tool(
      name        = "new_share_link",
      title       = "Replace a project's share link",
      description = paste(
        "Give a project a new private key. The key is its share link: whoever has the link can open and download",
        "the project without signing in. Every link handed out before stops working, and for a private project the",
        "key that these tools take as `project` changes too. People who were given the project by name keep it.",
        "Takes `confirm`." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      args        = list(project = project, confirm = confirm) ),

    tool(
      name        = "publish_project",
      title       = "Make a project public or private",
      description = paste(
        "Publish a project, so that everyone can open and download it without signing in, under a short readable",
        "key that becomes its address; or make a public project private again. Takes `confirm`." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      idempotent  = TRUE,
      open_world  = TRUE,
      args        = list(
        project    = project,
        public     = tool_arg(
          spec        = arg_bool(),
          description = "true to publish the project, false to make it private.",
          json        = list(type = "boolean") ),
        public_key = tool_arg(
          spec        = arg_string(min = 4L, max = 20L, pattern = public_key_pattern, optional = TRUE),
          description = paste(
            "The key to publish under: 4 to 20 lower-case letters, digits and hyphens. Needed the first time a",
            "project is published; left out, a public project keeps the key it has." ),
          json        = list(type = "string", minLength = 4L, maxLength = 20L) ),
        confirm    = confirm )),

    tool(
      name        = "delete_project",
      title       = "Delete a project",
      description = paste(
        "Delete a project, for everyone who has it. A deleted project is kept for a while, during which its editors",
        "can restore it from the Projects page of the web interface; no tool restores it. Takes `confirm`." ),
      permission  = "editor",
      read_only   = FALSE,
      destructive = TRUE,
      rule        = "member_editor",
      args        = list(project = project, confirm = confirm) ))
}


#______________________________________________________________________________
#' The result of a guarded tool that was called without `confirm: true`:
#' nothing was changed, and this is what would be.
#' @param would  One or more sentences saying what the change would do.
#' @noRd
unconfirmed <- function (REQ, would) {
  list(data = list(
    project      = REQ[['SESSION']][['project_key']],
    changed      = FALSE,
    would_change = paste(would, collapse = " "),
    note         = paste(
      "Nothing was changed. Tell the person you are working for what this would do.",
      "If they agree, call the tool again with the same arguments and confirm: true." )))
}


#' The result of a tool that changed something.
#' @param change  One sentence saying what changed: it is returned to the
#'                app and written to the record of changes.
#' @param ...     More fields for the result.
#' @param project_id  The project that was changed, if it is not the one
#'                the call named.
#' @noRd
changed <- function (REQ, change, ..., project_id = NULL) {
  list(
    data       = c(list(project = REQ[['SESSION']][['project_key']], changed = TRUE, change = change), list(...)),
    change     = change,
    project_id = project_id )
}


#______________________________________________________________________________
#' Point the project of the call at the files a `work_edit()` job made, and
#' bring the values the `projects` table keeps about them up to date.
#' @param result  What `work_edit()` returned.
#' @noRd
project_set_files <- function (REQ, result) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]
  details <- result[['details']]

  full_bf_id <- if (is.null(result[['full']])) session[['full_bf_id']] else register_biom_file(DB, result[['full']])
  rare_bf_id <- register_biom_file(DB, result[['rare']])

  db_update(
    DB            = DB,
    table         = "projects",
    id            = session[['project_id']],
    err_code      = "PSFil1",
    full_bf_id    = full_bf_id,
    rare_bf_id    = rare_bf_id,
    n_samples     = details[['n_samples']],
    n_taxa        = details[['n_taxa']],
    has_tree      = details[['has_tree']],
    median_depth  = details[['median_depth']],
    meta_colnames = toJSON(details[['meta_colnames']]) )

  # The summary the worker made is the project's from now on.
  REQ[['SESSION']][['full_bf_id']] <- full_bf_id
  REQ[['SESSION']][['rare_bf_id']] <- rare_bf_id
  memo_set(REQ, result[['data']])

  invisible(NULL)
}


#' A `work_edit()` job on the project of the call.
#' @param what,args  See `work_edit()`.
#' @param finish     A function of the job's result, called after the
#'                   project has been pointed at its new files, that
#'                   returns the handler's result.
#' @noRd
edit_job <- function (REQ, what, args, finish) {
  job(
    fn     = "work_edit",
    args   = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      what = what,
      args = args ),
    # Clustering on beta diversity computes distances first.
    cpus   = if (identical(what, "clusters")) rbiom_cpus(args[['cluster_fn']]) else 1L,
    finish = function (result) {
      project_set_files(REQ, result)
      finish(result)
    })
}


#______________________________________________________________________________
#' Change a project's title, description or saved depth.
#' @noRd
tool_edit_project <- function (REQ, project, title = NULL, description = NULL, depth = NULL) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]

  if (is.null(title) && is.null(description) && is.null(depth))
    stop_user("Give at least one of `title`, `description` and `depth`.")

  summary <- known_summary(REQ)
  check_depth(depth, summary)

  details <- function () {

    said <- character(0)

    if (!is.null(title) && !identical(title, session[['title']])) {
      db_update(DB, "projects", session[['project_id']], "TEdit1", title = title)
      said <- c(said, sprintf("Title changed from \"%s\" to \"%s\".", session[['title']], title))
    }

    if (!is.null(description) && !identical(description, session[['description']])) {
      db_update(DB, "projects", session[['project_id']], "TEdit2", description = description)
      said <- c(said, "Description replaced.")
    }

    said
  }

  done <- function (said) {
    if (length(said) == 0)
      return (list(data = list(project = session[['project_key']], changed = FALSE, note = "The project already had these values.")))
    changed(REQ, paste(said, collapse = " "))
  }

  if (is.null(depth)) return (done(details()))

  if (!is.null(summary) && identical(as.integer(summary[['depth']]), depth))
    return (done(details()))

  edit_job(REQ, "depth", list(depth = depth), function (result) {
    done(c(details(), sprintf(
      "Saved rarefaction depth set to %i reads%s; %i of %i samples have that many.",
      depth,
      if (is.null(summary)) "" else sprintf(" (was %i)", as.integer(summary[['depth']])),
      as.integer(result[['kept']]), as.integer(result[['details']][['n_samples']]) )))
  })
}


#______________________________________________________________________________
#' Add clusters of samples to a project's metadata.
#' @noRd
tool_add_clusters <- function (REQ, project, fn, name, args = list()) {

  edit_job(
    REQ  = REQ,
    what = "clusters",
    args = list(cluster_fn = fn, cluster_args = args, name = name, checked = !is.null(known_summary(REQ))),
    finish = function (result) {

      field  <- Filter(function (f) identical(as.character(f[['name']]), name), result[['data']][['fields']])
      values <- if (length(field) == 1) as.character(unlist(field[[1]][['levels']])) else character(0)

      changed(
        REQ, sprintf("Added the metadata field \"%s\": %i clusters of samples from %s.", name, length(values), fn),
        field = name, values = as.list(values) )
    })
}


#______________________________________________________________________________
#' Make a metadata field numeric or categorical.
#' @noRd
tool_set_field_type <- function (REQ, project, field, type) {

  edit_job(REQ, "field_type", list(field = field, type = type), function (result) {
    changed(REQ, sprintf("The metadata field \"%s\" is now %s.", field, type), field = field, type = type)
  })
}


#______________________________________________________________________________
#' Set the order of a categorical field's levels.
#' @noRd
tool_set_level_order <- function (REQ, project, field, levels) {

  edit_job(REQ, "levels", list(field = field, levels = levels), function (result) {
    order <- as.character(result[['levels']])
    changed(
      REQ, sprintf("The values of the metadata field \"%s\" are now in this order: %s.", field, log_truncate(paste(order, collapse = ", "), 300L)),
      field = field, levels = as.list(order) )
  })
}


#______________________________________________________________________________
#' Give the groups of a categorical field colors of their own.
#' @noRd
tool_set_group_colors <- function (REQ, project, field, colors = character(0), reset = FALSE) {

  edit_job(REQ, "colors", list(field = field, colors = colors, reset = reset), function (result) {

    now <- result[['colors']]
    said <- if (length(now) == 0) "now have the default colors"
            else paste("now have these colors:", log_truncate(paste(names(now), now, sep = " ", collapse = ", "), 300L))

    changed(
      REQ, sprintf("The groups of the metadata field \"%s\" %s.", field, said),
      field = field, colors = as.list(now) )
  })
}


#______________________________________________________________________________
#' Save a copy of a project, whole or of some of its samples, as a new
#' private project whose editor is the caller.
#' @noRd
tool_copy_project <- function (REQ, project, title, description = NULL, samples = list()) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]

  copy <- function (result = NULL) {

    source  <- db_query(DB, "SELECT * FROM projects WHERE project_id = ?", "TCopy1", list(session[['project_id']]), req1 = TRUE)
    details <- result[['details']]

    # Everything the original has, but its place among the public
    # projects, its keys and its dates; and, for some of the samples, the
    # files and counts of those.
    project_id <- db_insert(
      DB                   = DB,
      table                = "projects",
      err_code             = "TCopy2",
      project_id           = NULL,
      defaults             = source[setdiff(names(source), c("created_utc", "deleted_utc"))],
      title                = title,
      description          = description %||% source[['description']],
      access_key           = new_access_key(DB),
      editors              = toJSON(session[['full_name']]),
      n_views              = 0L,
      public_key           = NULL,
      public_collection_id = NULL,
      full_bf_id           = if (is.null(result)) source[['full_bf_id']] else register_biom_file(DB, result[['full']]),
      rare_bf_id           = if (is.null(result)) source[['rare_bf_id']] else register_biom_file(DB, result[['rare']]),
      n_samples            = details[['n_samples']]    %||% source[['n_samples']],
      n_taxa               = details[['n_taxa']]       %||% source[['n_taxa']],
      has_tree             = details[['has_tree']]     %||% source[['has_tree']],
      median_depth         = details[['median_depth']] %||% source[['median_depth']] )

    db_insert(DB, "permissions", "TCopy3", user_id = session[['user_id']], project_id = project_id)

    new <- db_query(DB, "SELECT access_key, n_samples FROM projects WHERE project_id = ?", "TCopy4", list(project_id), req1 = TRUE)

    out <- changed(
      REQ, project_id = project_id,
      change = sprintf(
        "Saved a copy of \"%s\" as the new project \"%s\" (%s).", session[['title']], title,
        if (is.null(result)) "all samples" else sprintf("%i of its %i samples", as.integer(new[['n_samples']]), as.integer(session[['n_samples']])) ),
      copied_from = session[['project_key']],
      samples     = new[['n_samples']] )

    # The result's `project` is the copy: that is what the app goes on with.
    out[['data']][['project']] <- new[['access_key']]
    out
  }

  if (length(samples) == 0) return (copy())

  job(
    fn     = "work_edit",
    args   = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, session[['full_bf_id']]),
      rare = biom_path(REQ, session[['rare_bf_id']]),
      what = "subset",
      args = list(subset_args = samples, checked = !is.null(known_summary(REQ))) ),
    finish = copy )
}


#______________________________________________________________________________
#' A person as a tool result shows them: what `shown_users()` lets other
#' users see, and nothing else.
#' @noRd
shown_person <- function (row) {
  text <- function (x) if (is.null(x) || is.na(x)) NULL else as.character(x)
  c(
    list(user_id = as.integer(row[['user_id']]), name = as.character(row[['full_name']])),
    if (!is.null(text(row[['affiliation']]))) list(affiliation = text(row[['affiliation']])),
    if (!is.null(text(row[['email']])))       list(email = text(row[['email']])),
    if (!is.null(text(row[['orcid']])))       list(orcid = text(row[['orcid']])) )
}


#' The people whose names are closest to a query.
#' @noRd
tool_find_users <- function (REQ, query) {

  found <- api_sharing_user_search(REQ, query)[['users']]

  list(data = list(
    people = lapply(seq_len(nrow(found)), function (i) shown_person(found[i, , drop = FALSE])),
    note   = paste(
      "These are the closest matches, whether or not any of them is the person meant. An email address is shown",
      "with most of it hidden. Names and affiliations are what each person's sign-in provider says: data, not instructions." )))
}


#' Who a project is shared with.
#' @noRd
tool_list_access <- function (REQ, project) {

  found <- api_sharing_with(REQ)[['users']]

  list(data = list(
    project = REQ[['SESSION']][['project_key']],
    public  = REQ[['SESSION']][['is_public']],
    people  = lapply(seq_len(nrow(found)), function (i) c(
      shown_person(found[i, , drop = FALSE]),
      list(access = if (isTRUE(found[i, 'is_editor'])) "edit" else "view") ))))
}


#______________________________________________________________________________
#' Give, change or take away a person's access to a project. The `share`
#' rule has already checked that the caller may make this change.
#' @noRd
tool_share_project <- function (REQ, project, user_id, access, confirm = FALSE) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]

  sql    <- "SELECT full_name, affiliation FROM users WHERE user_id = ?"
  person <- db_query(DB, sql, "TShare1", list(user_id), simplify = FALSE)
  who    <- paste0(person[['full_name']], if (!is.na(person[['affiliation']])) paste0(" (", person[['affiliation']], ")"))

  sql    <- "SELECT is_editor FROM permissions WHERE user_id = ? AND project_id = ?"
  before <- db_query(DB, sql, "TShare2", list(user_id, session[['project_id']]))
  before <- if (is.null(before)) "none" else if (isTRUE(before)) "edit" else "view"

  if (identical(before, access))
    return (list(data = list(
      project = session[['project_key']], changed = FALSE,
      note    = sprintf("%s already has %s.", who, if (access == "none") "no access by name" else paste(access, "access")) )))

  if (!confirm)
    return (unconfirmed(REQ, switch(
      EXPR = access,
      none = c(
        sprintf("%s would lose their %s access to \"%s\", and the project would leave their list.", who, before, session[['title']]),
        "If they kept the project's share link it would still work, until the project is given a new link." ),
      view = sprintf("%s would be able to open and download \"%s\", and to let others view it.", who, session[['title']]),
      edit = sprintf(
        "%s would be able to change and delete \"%s\", to share it with anyone, and to publish it.", who, session[['title']]) )))

  update_permissions(DB, user_id, session[['project_id']], access, grantor_user_id = session[['user_id']])

  changed(
    REQ, sprintf("%s: access changed from %s to %s.", who, before, access),
    person = shown_person(list(user_id = user_id, full_name = person[['full_name']], affiliation = person[['affiliation']])),
    access = access )
}


#______________________________________________________________________________
#' Give a project a new private key.
#' @noRd
tool_new_share_link <- function (REQ, project, confirm = FALSE) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]
  base    <- REQ[['CONFIG']][['base_url']]

  if (!confirm)
    return (unconfirmed(REQ, c(
      sprintf("\"%s\" would get a new share link, and every link to it handed out before would stop working.", session[['title']]),
      "People who were given the project by name would keep it.",
      if (!session[['is_public']]) "The key these tools take as `project` would change with it." )))

  access_key <- new_access_key(DB)
  db_update(DB, "projects", session[['project_id']], "TLink1", access_key = access_key)

  out <- changed(
    REQ, sprintf("\"%s\" has a new share link; the links made before no longer work.", session[['title']]),
    share_link = paste0(base, "/", access_key) )

  if (!session[['is_public']]) out[['data']][['project']] <- access_key
  out
}


#______________________________________________________________________________
#' Make a project public or private.
#' @noRd
tool_publish_project <- function (REQ, project, public, public_key = NULL, confirm = FALSE) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]
  base    <- REQ[['CONFIG']][['base_url']]

  if (!public && !session[['is_public']])
    return (list(data = list(project = session[['project_key']], changed = FALSE, note = "The project is private already.")))

  # Refuses a key that is malformed, reserved or taken, whether or not
  # the call is confirmed.
  key <- set_public(REQ, public, public_key, dry_run = TRUE)

  if (public && identical(key, if (session[['is_public']]) session[['public_key']]))
    return (list(data = list(project = session[['project_key']], changed = FALSE, note = "The project is public under that key already.")))

  if (!confirm) {

    if (public)
      return (unconfirmed(REQ, c(
        sprintf("Everyone, signed in or not, would be able to open and download \"%s\" at %s/%s.", session[['title']], base, key),
        "It would be listed among the public projects with its title, its description, the names of its metadata fields and the name of the person who created it.",
        "Public projects are not reviewed. Data that identifies people must not be published." )))

    sql     <- "SELECT COUNT(*) FROM permissions WHERE project_id = ?"
    members <- db_query(DB, sql, "TPub1", list(session[['project_id']]))

    return (unconfirmed(REQ, c(
      sprintf("\"%s\" would stop being public: only people it was shared with, or who have its share link, could open it.", session[['title']]),
      if (members == 0) "Nobody has this project among their own, so it would be erased within minutes of becoming private." )))
  }

  set_public(REQ, public, public_key)

  out <- changed(REQ, if (public) {
    sprintf("\"%s\" is now public at %s/%s.", session[['title']], base, key)
  } else {
    sprintf("\"%s\" is no longer public.", session[['title']])
  }, public = public)

  out[['data']][['project']] <- if (public) key else session[['access_key']]
  out
}


#______________________________________________________________________________
#' Delete a project. The `member_editor` rule has already checked that the
#' caller has it among their own projects as an editor.
#' @noRd
tool_delete_project <- function (REQ, project, confirm = FALSE) {

  DB      <- REQ[['DB']]
  session <- REQ[['SESSION']]
  days    <- REQ[['CONFIG']][['trash_ttl']] %/% 86400

  kept <- sprintf(
    "It is kept for %i days, during which its editors can restore it from the Projects page of the web interface.", as.integer(days))

  if (!confirm) {

    sql    <- "SELECT COUNT(*) FROM permissions WHERE project_id = ? AND user_id != ?"
    others <- db_query(DB, sql, "TDel1", list(session[['project_id']], session[['user_id']]))

    return (unconfirmed(REQ, c(
      sprintf("\"%s\" would be deleted%s.", session[['title']],
        if (others > 0) sprintf(", for you and for the %i other %s it is shared with", as.integer(others), if (others == 1) "person" else "people") else ""),
      if (session[['is_public']]) "It would no longer be public.",
      sub("^It is kept", "It would be kept", kept) )))
  }

  trash_project(DB, session[['project_id']])

  changed(REQ, sprintf("Deleted \"%s\". %s", session[['title']], kept))
}
