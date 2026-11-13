#______________________________________________________________________________
# The tools an AI app can call through the MCP endpoint (`R/mcp.R`).
#
# `mcp_tool_table()` is to tools what the route table is to routes: every
# tool, with its name, what it tells a model about itself, the permission it
# needs, and its arguments. `tool_call()` checks a call against that
# declaration the way the router checks a request: who is calling, whether
# they may use the project they name, and whether each argument is valid.
# The handlers (`tool_*()`) check nothing themselves.
#
# A tool call has no browser tab behind it. The caller is a user (with
# `auth = "none"`, the local owner), each call names its project by key, and
# the work is done on the saved project, never on a tab's unsaved changes.
# For the length of the call, `REQ$SESSION` holds that user and project in
# the shape a tab's session has, without a session id or key, so that the
# argument checks and the helpers that turn stored files into paths work as
# they do for the browser. Jobs are submitted without a session: a model
# may call several tools at once, and none of them replaces another.
#
# Figures, tables and exports are written under `<temp_dir>/mcp/`, each
# call in a directory of its own with an unguessable name, and are removed
# by the cleanup timer after `session_hours`, like a tab's files.
#
# Everything a tool returns that came out of a user's file (titles,
# descriptions, field names and values, taxa, table cells) is a value in
# the result's data. None of it is ever part of a tool's name, description
# or schema, which are fixed text written here.
#
# The first tools only read and compute. A tool that changes data would
# declare `read_only = FALSE` and the permission it needs; such tools are
# offered only when the server's configuration allows them (`mcp_writes`),
# which nothing sets yet.
#______________________________________________________________________________


# What a tool may ask of its caller. `session`: nothing beyond being a
# caller. `viewer`, `editor`: that access to the project the call names.
tool_levels <- c("session", "viewer", "editor")

# Rows of a statistics table in a result, by default and at most.
mcp_rows_default <- 50L
mcp_rows_max     <- 500L

# Most projects `list_projects` returns.
mcp_projects_max <- 200L

# In `describe_project`: most values listed for a categorical field, most
# taxa named per rank, most rarefaction depths listed.
mcp_levels_max <- 50L
mcp_taxa_max   <- 10L
mcp_depths_max <- 40L


#______________________________________________________________________________
#' Declare one tool.
#'
#' @param name         The tool's name, as the model calls it. The handler
#'                     is the function `tool_<name>`.
#' @param title        A short name for people.
#' @param description  What the tool does and returns, for the model.
#' @param permission   One of `tool_levels`. Whatever the level, a call that
#'                     names a project is refused unless the caller can read
#'                     that project.
#' @param read_only    Does the tool leave all data as it was?
#' @param args         A named list of declarations made with `tool_arg()`.
#'                     An argument called `project` is a project key. The
#'                     handler takes each under its own name, except
#'                     `function`, which it takes as `fn` (`handler_args()`).
#' @return A list of class `tool`.
#' @noRd
tool <- function (name, title, description, permission, args = list(), read_only = TRUE) {

  stopifnot(
    is_scalar_character(name), grepl("^[a-z][a-z_]{0,63}$", name),
    is_scalar_character(title),
    is_scalar_character(description),
    is_one_of(permission, tool_levels),
    is_bool(read_only),
    is.list(args),
    length(args) == 0 || (!is.null(names(args)) && all(grepl("^[a-z_]+$", names(args)))),
    all(vapply(args, function (a) inherits(a, "arg_spec") && is.list(a[['json']]), logical(1))),
    permission == "session" || "project" %in% names(args) )

  structure(class = "tool", list(
    name        = name,
    title       = title,
    description = description,
    handler     = paste0("tool_", name),
    permission  = permission,
    read_only   = read_only,
    strict      = TRUE,
    args        = args ))
}


#' Declare one argument of a tool: how it is checked, and how it is
#' described to the model.
#'
#' @param spec         An argument declaration from an `arg_*()` function
#'                     (`R/router.R`).
#' @param description  What the argument means, for the model.
#' @param json         The argument's JSON Schema, without its description.
#' @noRd
tool_arg <- function (spec, description, json) {
  stopifnot(inherits(spec, "arg_spec"), is_scalar_character(description), is.list(json))
  spec[['json']] <- c(json, list(description = description))
  spec
}


#' The image settings of a `make_plot` call: a PNG of `width` by `height`
#' pixels. What the handler gets is a complete set of arguments for
#' `ggsave()`, as from `check_save_args()`.
#' @noRd
arg_image <- function (...) {
  arg_spec("image", ..., check = function (x) {

    if (!is.list(x) || is.data.frame(x) || (length(x) > 0 && is.null(names(x))) || !all(names(x) %in% c("width", "height", "dpi")))
      stop("may only have 'width', 'height' and 'dpi'")

    args <- check_save_args(c(
      list(device = "png", units = "px"),
      utils::modifyList(mcp_image_default, x) ))

    for (side in c("width", "height"))
      if (args[[side]] < mcp_image_pixels[[1]] || args[[side]] > mcp_image_pixels[[2]])
        stop("has a ", side, " outside ", mcp_image_pixels[[1]], " to ", mcp_image_pixels[[2]], " pixels")

    args
  })
}

# The size of a figure when the call does not say, and the range a side may
# have. Larger images are for the browser: an image in a tool result is
# sent as text inside JSON.
mcp_image_default <- list(width = 900, height = 600, dpi = 100)
mcp_image_pixels  <- c(200, 2000)


#______________________________________________________________________________
#' The tool table: every tool, in the order clients are shown them.
#' @return A list of `tool` objects, named by tool.
#' @noRd
mcp_tool_table <- function () {

  schema_once("mcp_tools", {

    plots <- schema_fns("plot")
    stats <- schema_fns("stats")

    labels <- function (fns) paste0(
      fns, " (", vapply(fns, function (fn) schema_functions[[fn]][['label']], character(1)), ")", collapse = "; " )

    project <- tool_arg(
      spec        = arg_string(min = 4L, max = 40L, pattern = access_key_pattern),
      description = "The project's key, as list_projects gives it.",
      json        = list(type = "string") )

    depth <- tool_arg(
      spec        = arg_int(min = 1L, optional = TRUE),
      description = paste(
        "Rarefaction depth: every sample is subsampled to this many reads, and samples with fewer are left out.",
        "Leave it out to use the depth the project was saved with. describe_project lists the depths that make sense." ),
      json        = list(type = "integer", minimum = 1L) )

    samples <- tool_arg(
      spec        = arg_subset_args(optional = TRUE),
      description = paste(
        "Use only some of the samples. `cat` keeps the samples whose value of a categorical field is in the list given",
        "(the list's order is also the order of the groups in a figure). `num` keeps the samples whose value of a numeric",
        "field lies between the two numbers given." ),
      json        = list(
        type       = "object",
        properties = list(
          cat = list(type = "object", additionalProperties = list(type = "array", items = list(type = "string"), minItems = 1L)),
          num = list(type = "object", additionalProperties = list(type = "array", items = list(type = "number"), minItems = 2L, maxItems = 2L)) ),
        additionalProperties = FALSE ))

    fn_args <- tool_arg(
      spec        = arg_fn_args("function", optional = TRUE),
      description = paste(
        "The rbiom function's own arguments, by name, for example {\"stat.by\": \"Treatment\"}.",
        "describe_function gives the arguments a function takes. Anything left out takes rbiom's default." ),
      json        = list(type = "object") )

    exports <- c("biom", "xlsx", "metadata", "taxonomy", "tree", "alpha", "beta", "taxa")
    if (!has_package(rbiom_schema()[['write_xlsx']][['needs']]))
      exports <- setdiff(exports, "xlsx")

    tools <- list(

      tool(
        name        = "list_projects",
        title       = "List projects",
        description = paste(
          "List the projects (microbiome datasets) you can open: the caller's own and the public examples.",
          "Each has a key, which the other tools take as `project`, a title, and its numbers of samples and taxa." ),
        permission  = "session" ),

      tool(
        name        = "describe_project",
        title       = "Describe a project",
        description = paste(
          "Describe one project: its title and description, how many samples and taxa it has, whether it has a",
          "phylogenetic tree (UniFrac and Faith's PD need one), the rarefaction depth it was saved with and the depths",
          "that are possible, its metadata fields (categorical with their values, numeric with their range), and its",
          "taxonomic ranks with the most abundant taxa of each. Call this before analysing a project: the other tools",
          "take field names, ranks and taxa exactly as they are spelled here." ),
        permission  = "viewer",
        args        = list(project = project) ),

      tool(
        name        = "describe_function",
        title       = "Describe an rbiom function",
        description = paste0(
          "Give the arguments of one of the rbiom functions that run_stats and make_plot can run, as a JSON Schema:",
          " each argument's type, choices, default and meaning, and the rules about which go together.",
          " With `project`, metadata fields, ranks and diversity metrics are listed as that project has them.",
          " Statistics: ", labels(stats), ". Plots: ", labels(plots), "." ),
        permission  = "session",
        args        = list(
          `function` = tool_arg(
            spec        = arg_choice(c(stats, plots)),
            description = "The rbiom function to describe.",
            json        = list(type = "string", enum = as.list(c(stats, plots))) ),
          project    = tool_arg(
            spec        = arg_string(min = 4L, max = 40L, pattern = access_key_pattern, optional = TRUE),
            description = "A project's key, to have its fields, ranks and metrics listed in the schema.",
            json        = list(type = "string") ))),

      tool(
        name        = "run_stats",
        title       = "Run a statistical test",
        description = paste0(
          "Run one of rbiom's statistics functions on a project and return its table: one row per comparison or",
          " model term, with p-values, adjusted p-values and effect sizes. No figure is drawn, so this is the quick way",
          " to screen metadata fields. Functions: ", labels(stats), ".",
          " The result holds the first `max_rows` rows, sorted as rbiom sorts them (smallest p-value first), says how",
          " many rows there are in all, links to the whole table as a CSV file, and gives the R code that reproduces it.",
          " Numbers in the result are rounded to four significant digits; the CSV file has them in full." ),
        permission  = "viewer",
        args        = list(
          project    = project,
          `function` = tool_arg(
            spec        = arg_choice(stats),
            description = "The rbiom statistics function to run.",
            json        = list(type = "string", enum = as.list(stats)) ),
          args       = fn_args,
          depth      = depth,
          samples    = samples,
          max_rows   = tool_arg(
            spec        = arg_int(min = 1L, max = mcp_rows_max, default = mcp_rows_default),
            description = "The most rows of the table to return.",
            json        = list(type = "integer", minimum = 1L, maximum = mcp_rows_max, default = mcp_rows_default) ))),

      tool(
        name        = "make_plot",
        title       = "Make a figure",
        description = paste0(
          "Draw one of rbiom's plots for a project. Functions: ", labels(plots), ".",
          " The result is the figure as a PNG image, a link to the same file, the statistics table behind the figure",
          " when it has one (its first ", mcp_rows_default, " rows; use run_stats for more), and the R code that",
          " reproduces the figure with rbiom and with ggplot2." ),
        permission  = "viewer",
        args        = list(
          project    = project,
          `function` = tool_arg(
            spec        = arg_choice(plots),
            description = "The rbiom plot function to run.",
            json        = list(type = "string", enum = as.list(plots)) ),
          args       = fn_args,
          depth      = depth,
          samples    = samples,
          image      = tool_arg(
            spec        = arg_image(default = arg_image()[['check']](list())),
            description = "The image's size in pixels, and its resolution, which sets the size of text and lines.",
            json        = list(
              type       = "object",
              properties = list(
                width  = list(type = "integer", minimum = mcp_image_pixels[[1]], maximum = mcp_image_pixels[[2]], default = mcp_image_default[['width']]),
                height = list(type = "integer", minimum = mcp_image_pixels[[1]], maximum = mcp_image_pixels[[2]], default = mcp_image_default[['height']]),
                dpi    = list(type = "integer", minimum = 30L, maximum = 1200L, default = mcp_image_default[['dpi']]) ),
              additionalProperties = FALSE )))),

      tool(
        name        = "export",
        title       = "Export data",
        description = paste(
          "Write part of a project to a file and return a link to download it: `biom` (the whole dataset as a BIOM",
          "file), `xlsx` (an Excel workbook of counts, metadata, taxonomy and diversity), `metadata` or `taxonomy`",
          "(CSV), `tree` (Newick), `alpha` (alpha diversity of every sample, CSV), `beta` (a distance matrix between",
          "samples, CSV; always rarefied) or `taxa` (abundances at one rank, CSV). The link works for a day." ),
        permission  = "viewer",
        args        = list(
          project  = project,
          what     = tool_arg(
            spec        = arg_choice(exports),
            description = "What to export.",
            json        = list(type = "string", enum = as.list(exports)) ),
          rarefied = tool_arg(
            spec        = arg_bool(default = FALSE),
            description = "Use the counts rarefied to the project's saved depth, instead of all reads?",
            json        = list(type = "boolean", default = FALSE) ),
          format   = tool_arg(
            spec        = arg_choice(c("json", "hdf5", "tab"), default = "json"),
            description = "For `biom`: the file format. `tab` is a plain table of counts.",
            json        = list(type = "string", enum = list("json", "hdf5", "tab"), default = "json") ),
          metric   = tool_arg(
            spec        = arg_metric("bdiv_distmat", "bdiv", default = "bray"),
            description = "For `beta`: the distance metric, by rbiom's id, such as \"bray\" or \"weighted_unifrac\".",
            json        = list(type = "string", default = "bray") ),
          rank     = tool_arg(
            spec        = arg_rank(default = ".otu"),
            description = "For `taxa`: a taxonomic rank of the project, or \"otu\".",
            json        = list(type = "string", default = "otu") ))) )

    names(tools) <- vapply(tools, function (t) t[['name']], character(1))
    tools
  })
}


#' The tools a server offers: all that only read, and those that change
#' data only if its configuration says so.
#' @noRd
mcp_tools <- function (config = list()) {
  Filter(function (t) t[['read_only']] || isTRUE(config[['mcp_writes']]), mcp_tool_table())
}


#______________________________________________________________________________
#' A tool as `tools/list` shows it.
#' @noRd
tool_definition <- function (tool) {

  args     <- tool[['args']]
  required <- names(args)[!vapply(args, function (a) a[['optional']], logical(1))]

  list(
    name        = tool[['name']],
    title       = tool[['title']],
    description = tool[['description']],
    inputSchema = c(
      list(type = "object"),
      if (length(args) > 0)     list(properties = lapply(args, function (a) a[['json']])),
      if (length(required) > 0) list(required = as.list(required)),
      list(additionalProperties = FALSE) ),
    annotations = list(
      readOnlyHint    = tool[['read_only']],
      destructiveHint = FALSE,
      idempotentHint  = tool[['read_only']],
      openWorldHint   = FALSE ))
}


#______________________________________________________________________________
#' Who is calling the MCP endpoint.
#'
#' Without accounts it is the local owner. (The route does not exist with
#' `auth = "oidc"`, where a caller will be the user of a bearer token.)
#' @return `list(user_id)`
#' @noRd
mcp_caller <- function (REQ) {

  if (!identical(REQ[['CONFIG']][['auth']], "none"))
    stop_unauthorized("Sign-in for AI apps is not available on this server.")

  list(user_id = local_owner(REQ[['DB']]))
}


#______________________________________________________________________________
#' Check a tool call against the tool's declaration, then run its handler.
#'
#' The order is the router's: who is calling, whether they may do this with
#' the project they name, whether the arguments are valid, and only then
#' the handler.
#'
#' @param tool  A `tool`.
#' @param args  The call's arguments, as they came.
#' @return What the handler returns: `list(data, image)`, or a job whose
#'         `finish` returns that. Stops with an `atima_http_error` if the
#'         call is refused.
#' @noRd
tool_call <- function (REQ, tool, args) {

  caller <- mcp_caller(REQ)

  REQ[['SESSION']] <- list(user_id = caller[['user_id']])

  if (is_scalar_character(args[['project']]) && "project" %in% names(tool[['args']]))
    REQ[['SESSION']] <- caller_project(REQ[['DB']], caller[['user_id']], args[['project']], tool[['permission']])

  args <- validate_args(tool, args, REQ)

  names(args) <- handler_args(names(args))

  handler <- get(tool[['handler']], envir = asNamespace("atima"), mode = "function")
  do.call(handler, c(list(REQ = REQ), args))
}


#' The names under which a handler takes a tool's arguments. They are the
#' arguments' own names, but for `function`: that is the natural name for a
#' model to use, and a reserved word in R.
#' @noRd
handler_args <- function (names) {
  names[names == "function"] <- "fn"
  names
}


#______________________________________________________________________________
#' Finish a handler that needs the summary of the call's project.
#'
#' @param then  A function of the summary (`biom_summary()`) that returns
#'              the handler's result.
#' @return What `then` returns if the main process has the summary in
#'         memory; otherwise a job that fetches it first.
#' @noRd
with_summary <- function (REQ, then) {

  data <- memo_get(REQ)
  if (!is.null(data)) return (then(data))

  job(
    fn     = "work_summary",
    args   = list(
      ctx  = worker_ctx(REQ[['CONFIG']]),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]) ),
    finish = function (result) {
      memo_set(REQ, result[['data']])
      then(result[['data']])
    })
}


#' A new directory for one call's files, and the address it is served at.
#' The name cannot be guessed, as a session key cannot.
#' @return `list(dir, url)`
#' @noRd
mcp_files <- function (REQ) {
  name <- random_string(24)
  list(
    dir = file.path(REQ[['CONFIG']][['temp_dir']], "mcp", name),
    url = paste0(REQ[['CONFIG']][['base_url']], "/tmp/mcp/", name) )
}


#' Stop unless a project can be rarefied to a depth.
#' @param summary  The project's summary, or `NULL` if it is not known here,
#'                 in which case the worker finds out.
#' @noRd
check_depth <- function (depth, summary) {

  if (is.null(depth) || is.null(summary)) return (invisible(TRUE))

  deepest <- max(as.numeric(unlist(summary[['depth_options']])))

  if (depth > deepest)
    stop_user("Argument 'depth' is more than the ", deepest, " reads of this project's deepest sample.")

  invisible(TRUE)
}


#______________________________________________________________________________
#' A statistics table as a result holds it: column names once, then rows of
#' values, at most `max_rows` of them, with a note if rows were left out.
#'
#' @param table       A data frame, already cut to `max_rows` or not.
#' @param rows_total  How many rows the whole table has.
#' @param hint        What the caller can do to see more, for the note.
#' @return `list(columns, rows, rows_total, rows_returned, truncated)`, and
#'         `note` if rows were left out.
#' @noRd
table_data <- function (table, max_rows, rows_total = nrow(table), hint = NULL) {

  table <- utils::head(as.data.frame(table, stringsAsFactors = FALSE), max_rows)

  columns <- lapply(table, function (column) {
    if (is.numeric(column)) return (signif(column, 4L))
    if (is.logical(column)) return (column)
    as.character(column)
  })

  rows <- lapply(seq_len(nrow(table)), function (i) unname(lapply(columns, function (column) column[[i]])))

  truncated <- rows_total > nrow(table)

  # rbiom sorts its tables by p-value; say so only when it is so.
  p_values <- table[['p_val']]
  sorted   <- is.numeric(p_values) && !is.unsorted(p_values, na.rm = TRUE)

  c(
    list(
      columns       = as.list(names(table)),
      rows          = rows,
      rows_total    = rows_total,
      rows_returned = nrow(table),
      truncated     = truncated ),
    if (truncated) list(note = paste(c(
      sprintf(
        if (sorted) "Showing the %i rows with the smallest p-values, of %i." else "Showing the first %i rows of %i.",
        nrow(table), as.integer(rows_total) ),
      hint ), collapse = " ")) )
}


#' The R code that loads a project's data as a tool call used it.
#'
#' @param sample_set  `"full"` or `"rare"`: which counts the function took.
#' @param depth       The depth the call asked for, or `NULL` for the saved
#'                    one, which is what the `rare` download holds.
#' @param filtered    Did the call filter the samples?
#' @noRd
code_load <- function (REQ, sample_set, depth = NULL, filtered = FALSE) {

  base <- paste0(REQ[['CONFIG']][['base_url']], "/", REQ[['SESSION']][['project_key']])

  lines <- c(
    "library(rbiom)",
    if (sample_set == "rare" && !is.null(depth)) c(
      sprintf('biom <- as_rbiom("%s/full.json")', base),
      sprintf("biom <- rarefy(biom, depth = %i)", as.integer(depth)) )
    else
      sprintf('biom <- as_rbiom("%s/%s.json")', base, sample_set),
    if (filtered) "# The `samples` filter of the request is not part of this code." )

  paste(lines, collapse = "\n")
}


#______________________________________________________________________________
# The tools' handlers. Each is called as `tool_<name>(REQ, <arguments>)`
# after `tool_call()` has checked the call, and returns `list(data)` or
# `list(data, image)`, or a job that ends in one.
#______________________________________________________________________________


#______________________________________________________________________________
#' The projects the caller can open: those in their own tree, then the
#' public ones.
#' @noRd
tool_list_projects <- function (REQ) {

  DB      <- REQ[['DB']]
  user_id <- REQ[['SESSION']][['user_id']]

  sql <- paste0(
    "SELECT p.project_id, p.title, p.access_key, p.public_key, p.n_samples, p.n_taxa, p.has_tree,",
    "       m.permission_id",
    " FROM projects p",
    " LEFT JOIN permissions m ON m.project_id = p.project_id AND m.user_id = ?",
    " WHERE m.permission_id IS NOT NULL OR p.public_key IS NOT NULL",
    " ORDER BY (m.permission_id IS NULL), p.title, p.project_id",
    " LIMIT ?" )
  found <- db_query(DB, sql, "TLProj1", list(user_id, mcp_projects_max + 1L), simplify = FALSE)

  more  <- nrow(found) > mcp_projects_max
  found <- utils::head(found, mcp_projects_max)

  projects <- lapply(seq_len(nrow(found)), function (i) {
    row <- found[i, , drop = FALSE]
    list(
      project = if (is.na(row[['public_key']])) row[['access_key']] else row[['public_key']],
      title   = row[['title']],
      access  = project_access(DB, row[['project_id']], user_id),
      public  = !is.na(row[['public_key']]),
      samples = row[['n_samples']],
      taxa    = row[['n_taxa']],
      tree    = isTRUE(as.logical(row[['has_tree']])) )
  })

  list(data = c(
    list(projects = projects),
    if (more) list(note = sprintf("Only the first %i projects are listed.", mcp_projects_max)) ))
}


#______________________________________________________________________________
#' What a project holds.
#' @noRd
tool_describe_project <- function (REQ, project) {

  session <- REQ[['SESSION']]

  with_summary(REQ, function (summary) {

    fields <- lapply(summary[['fields']], function (field) {

      if (identical(as.character(field[['class']]), "numeric"))
        return (list(
          name  = as.character(field[['name']]),
          class = "numeric",
          min   = as.numeric(field[['min']]),
          max   = as.numeric(field[['max']]) ))

      levels <- as.character(unlist(field[['levels']]))

      c(
        list(
          name     = as.character(field[['name']]),
          class    = as.character(field[['class']]),
          n_values = length(levels),
          values   = as.list(utils::head(levels, mcp_levels_max)) ),
        if (length(levels) > mcp_levels_max) list(note = sprintf("Only the first %i values are listed.", mcp_levels_max)) )
    })

    ranks <- as.character(unlist(summary[['ranks']]))

    taxa <- lapply(ranks, function (rank) {
      names <- as.character(unlist(summary[['taxa']][[rank]]))
      list(rank = rank, n_taxa = length(names), most_abundant = as.list(utils::head(names, mcp_taxa_max)))
    })

    # Each depth in `depth_options` drops a different set of samples. A
    # long list is thinned evenly, keeping both ends.
    depths <- as.numeric(unlist(summary[['depth_options']]))
    if (length(depths) > mcp_depths_max)
      depths <- depths[unique(round(seq(1, length(depths), length.out = mcp_depths_max)))]

    list(data = list(
      project     = session[['project_key']],
      title       = session[['title']],
      description = html_text(session[['description']]),
      access      = session[['access']],
      public      = session[['is_public']],
      samples     = session[['n_samples']],
      taxa        = session[['n_taxa']],
      tree        = isTRUE(as.logical(summary[['tree']])),
      depth       = list(
        saved   = as.numeric(summary[['depth']]),
        lowest  = min(depths),
        highest = max(depths),
        options = as.list(depths),
        note    = paste(
          "Sample read counts, lowest to highest. Rarefying to a depth keeps the samples with at least that many",
          "reads; `saved` is the depth used when a call gives none." )),
      fields      = fields,
      ranks       = taxa ))
  })
}


#______________________________________________________________________________
#' The arguments of an rbiom function, as JSON Schema.
#' @noRd
tool_describe_function <- function (REQ, fn, project = NULL) {

  uses <- schema_functions[[fn]][['use']]

  describe <- function (summary = NULL) list(data = list(
    `function`  = fn,
    label       = schema_functions[[fn]][['label']],
    tool        = if (uses == "stats") "run_stats" else "make_plot",
    counts      = if (plot_sample_set(fn) == "full") "all reads (not rarefied); `depth` has no effect" else "rarefied to `depth`",
    args_schema = fn_json_schema(fn, summary) ))

  if (is.null(project)) return (describe())

  with_summary(REQ, describe)
}


#______________________________________________________________________________
#' Run a statistics function and return its table.
#' @noRd
tool_run_stats <- function (REQ, project, fn, args = list(), depth = NULL, samples = list(), max_rows = mcp_rows_default) {

  summary <- known_summary(REQ)
  files   <- mcp_files(REQ)

  check_depth(depth, summary)

  job(
    fn   = "work_stats",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      full        = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare        = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      out_dir     = files[['dir']],
      stats_fn    = fn,
      stats_args  = args,
      subset_args = samples,
      depth       = depth,
      max_rows    = max_rows,
      checked     = !is.null(summary) ),
    finish = function (result) {

      # The worker looked the summary up to check the arguments. It is the
      # saved project's, unless the call rarefied to a depth of its own.
      if (is.null(result[['rare']]) && !is.null(result[['data']]))
        memo_set(REQ, result[['data']])

      hint <- sprintf(paste(
        "To get fewer rows, name the taxa or choose a higher rank, split the question into several calls, or",
        "compare fewer groups with `samples`. Pass `max_rows` (up to %i) for more, or read the whole table",
        "from `table_url`." ), mcp_rows_max)

      list(data = c(
        list(
          project    = REQ[['SESSION']][['project_key']],
          `function` = fn ),
        if (!is.null(result[['title']]))    list(model = result[['title']]),
        table_data(result[['table']], max_rows, result[['rows_total']], hint),
        list(table_url = paste0(files[['url']], "/", result[['file']])),
        if (length(result[['warnings']]) > 0) list(warnings = as.list(result[['warnings']])),
        list(code = paste(c(
          code_load(REQ, plot_sample_set(fn), depth, length(samples) > 0),
          paste0("stats <- ", result[['cmd']]) ), collapse = "\n")) ))
    })
}


#______________________________________________________________________________
#' Draw a plot and return it with its statistics and code.
#' @noRd
tool_make_plot <- function (REQ, project, fn, args = list(), depth = NULL, samples = list(), image = NULL) {

  summary <- known_summary(REQ)
  files   <- mcp_files(REQ)

  check_depth(depth, summary)

  job(
    fn   = "work_plot",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      full        = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare        = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      out_dir     = files[['dir']],
      plot_fn     = fn,
      plot_args   = args,
      save_args   = image,
      subset_args = samples,
      depth       = depth,
      attrs       = TRUE,
      checked     = !is.null(summary),
      keys        = c("args", "samples") ),
    finish = function (result) {

      if (is.null(result[['rare']]) && !is.null(result[['data']]))
        memo_set(REQ, result[['data']])

      load <- code_load(REQ, plot_sample_set(fn), depth, length(samples) > 0)
      code <- result[['code']]

      stats <- result[['stats_table']]
      hint  <- "Use run_stats for more rows of a statistics table."

      list(
        image = read_file_raw(file.path(files[['dir']], result[['file']])),
        data  = c(
          list(
            project    = REQ[['SESSION']][['project_key']],
            `function` = fn,
            figure_url = paste0(files[['url']], "/", result[['file']]),
            width      = image[['width']],
            height     = image[['height']] ),
          if (!is.null(stats)) list(stats = c(
            if (!is.null(result[['stats_title']])) list(model = lapply(result[['stats_title']], as.character)),
            table_data(stats, mcp_rows_default, hint = hint) )),
          list(code = c(
            list(
              rbiom   = paste(c(load, paste0("p <- ", as.character(code[['rbiom']]))), collapse = "\n"),
              ggplot2 = paste(c(load, "library(ggplot2)", as.character(code[['ggplot2']])), collapse = "\n") ),
            if (!is.null(code[['stats']])) list(stats = as.character(code[['stats']])) )) ))
    })
}


#______________________________________________________________________________
#' Write part of a project to a file and return its address.
#' @noRd
tool_export <- function (REQ, project, what, rarefied = FALSE, format = "json", metric = "bray", rank = ".otu") {

  session <- REQ[['SESSION']]
  files   <- mcp_files(REQ)

  # A distance matrix compares samples at one depth; the workbook holds
  # both kinds of counts.
  sample_set <- if (what == "beta") "rare" else if (what == "xlsx") "full" else if (rarefied) "rare" else "full"

  file <- sprintf(
    "%s_%s.%s",
    if (what == "beta") paste0("beta_", metric) else what,
    if (what == "xlsx") "all" else sample_set,
    switch(what, tree = "tre", biom = format, xlsx = "xlsx", "csv") )

  job(
    fn   = "work_export",
    args = list(
      ctx         = worker_ctx(REQ[['CONFIG']]),
      src         = biom_path(REQ, session[[paste0(sample_set, "_bf_id")]]),
      dest        = file.path(files[['dir']], file),
      what        = what,
      format      = format,
      method      = metric,
      rank        = rank,
      title       = session[['title']],
      description = session[['description']],
      rare        = if (what == "xlsx") biom_path(REQ, session[['rare_bf_id']]) ),
    finish = function (result) list(data = list(
      project      = session[['project_key']],
      what         = what,
      counts       = if (what == "xlsx") "all reads and rarefied" else if (sample_set == "rare") "rarefied" else "all reads",
      file         = file,
      download_url = paste0(files[['url']], "/", file),
      note         = "The link stops working after a day." )) )
}
