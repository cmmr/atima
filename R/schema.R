#______________________________________________________________________________
# The schema: which rbiom functions atima exposes, what their parameters are,
# and whether a request's arguments are valid.
#
# rbiom describes its own functions (`rbiom::fn_schema()`: every parameter's
# type, choices, limits, default, and when it has any effect) and checks a
# set of arguments against that description without running the function
# (`rbiom::fn_check()`). This file adds what rbiom leaves to its callers:
#
#  * which functions are exposed (`schema_functions`), and which of their
#    parameters (everything rbiom does not mark R-only or deprecated);
#  * a label for each function and parameter, and its group, `basic` or
#    `advanced`;
#  * the same for the image settings (`save_args`) and the sample filter
#    (`subset_args`) of a plot request, which are atima's own;
#  * the schema as the browser gets it (`browser_schema_json()`), and as
#    JSON Schema (`fn_json_schema()`), the form tool definitions take.
#
# Everything here is a function of an rbiom function's name, a list of
# arguments and a project summary (`biom_summary()`). Nothing reads the
# request or the session, so the same checks serve any caller. They run in
# the main process: they look at a few kilobytes of description and never
# at a BIOM file.
#
# The `check_*()` functions stop with a plain error whose message completes
# the sentence "Argument '<name>' ...", which is how the router reports it.
#______________________________________________________________________________


# The rbiom functions a remote caller may run, with what atima calls them.
# `use` says how: `plot` through /api/plot (and the MCP tool `make_plot`),
# `clusters` through /api/metadata/add_clusters, and `stats`, a statistics
# table without a figure, through the MCP tool `run_stats` only
# (`R/mcp-tools.R`). `area` is for grouping them in a menu.
schema_functions <- list(
  adiv_boxplot   = list(use = "plot",     area = "alpha",       label = "Alpha diversity box plot"),
  adiv_corrplot  = list(use = "plot",     area = "alpha",       label = "Alpha diversity correlation"),
  bdiv_boxplot   = list(use = "plot",     area = "beta",        label = "Beta diversity box plot"),
  bdiv_corrplot  = list(use = "plot",     area = "beta",        label = "Beta diversity correlation"),
  bdiv_heatmap   = list(use = "plot",     area = "beta",        label = "Beta diversity heat map"),
  bdiv_ord_plot  = list(use = "plot",     area = "beta",        label = "Ordination"),
  rare_corrplot  = list(use = "plot",     area = "rarefaction", label = "Rarefaction curves"),
  rare_stacked   = list(use = "plot",     area = "rarefaction", label = "Reads per sample"),
  rare_multiplot = list(use = "plot",     area = "rarefaction", label = "Rarefaction overview"),
  taxa_boxplot   = list(use = "plot",     area = "taxa",        label = "Taxa abundance box plot"),
  taxa_corrplot  = list(use = "plot",     area = "taxa",        label = "Taxa abundance correlation"),
  taxa_heatmap   = list(use = "plot",     area = "taxa",        label = "Taxa abundance heat map"),
  taxa_stacked   = list(use = "plot",     area = "taxa",        label = "Taxa stacked bar plot"),
  taxa_forest    = list(use = "plot",     area = "taxa",        label = "Differential abundance forest plot"),
  taxa_clusters  = list(use = "clusters", area = "taxa",        label = "Cluster samples by taxa abundance"),
  bdiv_clusters  = list(use = "clusters", area = "beta",        label = "Cluster samples by beta diversity"),
  adiv_stats     = list(use = "stats",    area = "alpha",       label = "Alpha diversity statistics"),
  bdiv_stats     = list(use = "stats",    area = "beta",        label = "Beta diversity statistics"),
  taxa_stats     = list(use = "stats",    area = "taxa",        label = "Taxa abundance statistics"),
  taxa_da        = list(use = "stats",    area = "taxa",        label = "Differential abundance statistics") )

# The uses the browser has pages for. Its schema leaves the rest out.
schema_browser_uses <- c("plot", "clusters")


# Parameters that choose what a figure shows are `basic`; those that say how
# it is computed or styled are `advanced`. One rule, by name, the same in
# every function.
schema_basic <- c(
  "x", "adiv", "bdiv", "ord", "rank", "taxa", "layers", "stat.by", "facet.by",
  "colors", "shapes", "patterns", "test", "tracks", "regr", "label.by",
  "order.by", "rline", "k" )


# A label for every parameter. A parameter without one is shown under its
# own name (and reported by the tests).
schema_labels <- c(
  "x"            = "X axis",
  "adiv"         = "Alpha diversity metric",
  "bdiv"         = "Beta diversity metric",
  "ord"          = "Ordination method",
  "rank"         = "Taxonomic rank",
  "taxa"         = "Taxa",
  "layers"       = "Layers",
  "stat.by"      = "Compare groups",
  "facet.by"     = "Facet by",
  "colors"       = "Colors",
  "shapes"       = "Shapes",
  "patterns"     = "Patterns",
  "test"         = "Statistical test",
  "tracks"       = "Annotation tracks",
  "regr"         = "Numeric variable",
  "label.by"     = "Label samples by",
  "order.by"     = "Order samples by",
  "rline"        = "Rarefaction depth line",
  "k"            = "Number of clusters",
  "within"       = "Compare within",
  "between"      = "Compare between",
  "covariates"   = "Adjust for",
  "split.by"     = "Split by",
  "strata"       = "Blocking variable",
  "transform"    = "Transform values",
  "y.transform"  = "Y axis scale",
  "ties"         = "Rank ties",
  "p.adj"        = "P-value adjustment",
  "p.label"      = "P-value brackets",
  "p.top"        = "Most significant taxa",
  "p.sig"        = "Significance threshold",
  "prev.cut"     = "Minimum prevalence",
  "level"        = "Confidence level",
  "ci"           = "Error bars",
  "fit"          = "Trend line",
  "at"           = "Evaluate at",
  "alt"          = "Alternative hypothesis",
  "mu"           = "Reference value",
  "method"       = "Method",
  "seed"         = "Random seed",
  "permutations" = "Permutations",
  "alpha"        = "Generalized UniFrac alpha",
  "unc"          = "Unclassified taxa",
  "lineage"      = "Full lineage names",
  "other"        = "Sum other taxa",
  "flip"         = "Flip axes",
  "stripe"       = "Stripe background",
  "outliers"     = "Outliers",
  "xlab.angle"   = "X label angle",
  "caption"      = "Caption",
  "check"        = "Diagnostic plots",
  "counts"       = "Show counts",
  "labels"       = "Sample labels",
  "grid"         = "Color scale",
  "label"        = "Row and column labels",
  "label_size"   = "Label size",
  "rescale"      = "Rescale",
  "clust"        = "Clustering",
  "dist"         = "Distance for clustering",
  "trees"        = "Dendrograms",
  "asp"          = "Aspect ratio",
  "tree_height"  = "Dendrogram height",
  "track_height" = "Track height",
  "legend"       = "Legend position",
  "title"        = "Title" )


# Parameters rbiom lets a remote caller set but atima does not offer.
schema_hidden <- character(0)


# Computed once per process. rbiom's descriptions do not change while it is
# loaded, and neither does the set of installed packages that matters here.
schema_env <- new.env(parent = emptyenv())

schema_once <- function (key, code) {
  if (is.null(schema_env[[key]])) schema_env[[key]] <- code
  schema_env[[key]]
}


#______________________________________________________________________________
#' rbiom's description of the functions it covers, as plain nested lists.
#'
#' It is read through its JSON form so that every array is a list and every
#' single value a length-one vector, which is what converts back to the same
#' JSON.
#' @return A named list with one entry per function: `fn`, `returns`,
#'         `rules` and `params`.
#' @noRd
rbiom_schema <- function () {
  schema_once("rbiom", {

    schema <- fromJSON(rbiom_schema_json(), simplifyVector = FALSE)

    # rbiom's version number does not change while 4.0.0 is being written,
    # so the only way to tell a build that is too old is to look.
    if (is.null(schema[['taxa_forest']][['counts']]))
      stop(call. = FALSE,
        "The installed rbiom is too old for this version of atima: its fn_schema() ",
        "does not say which counts a function takes. Install the current rbiom from cmmr/rbiom.")

    schema
  })
}

#' rbiom's description as JSON text, and a hash of it. The hash changes when
#' rbiom's schema does, and also when ecodive's list of metrics does, which
#' rbiom reads when asked; rbiom's version number may stay the same.
#' @noRd
rbiom_schema_json <- function () {
  schema_once("rbiom_json", as.character(fn_schema(json = TRUE)))
}

rbiom_schema_hash <- function () {
  schema_once("rbiom_hash", paste(as.character(sha256(charToRaw(enc2utf8(rbiom_schema_json())))), collapse = ""))
}


#' Is an R package installed where this process can load it?
#' @noRd
has_package <- function (pkg) {
  all(nzchar(vapply(as.character(unlist(pkg)), function (p) system.file(package = p), character(1))))
}


#______________________________________________________________________________
#' The choices of a function's parameters that this server cannot offer,
#' because they need a package rbiom only suggests and it is not installed.
#'
#' @return A list named by parameter, each a character vector of package
#'         names, named by the choice that needs it. Empty when every
#'         choice can be used.
#' @noRd
schema_unavailable <- function (fn) {

  schema_once(paste0("unavailable_", fn), {

    out <- list()

    for (p in rbiom_schema()[[fn]][['params']]) {
      needs <- unlist(p[['choices_needs']])
      needs <- needs[!vapply(needs, has_package, logical(1))]
      if (length(needs) > 0) out[[p[['name']]]] <- needs
    }

    out
  })
}


#' The names of the exposed functions that are used in a given way.
#' @noRd
schema_fns <- function (use) {
  names(schema_functions)[vapply(schema_functions, function (f) f[['use']] == use, logical(1))]
}


#______________________________________________________________________________
#' The parameters of a function that a remote caller may set.
#'
#' @param fn  The name of an exposed rbiom function.
#' @return A list of rbiom's parameter descriptions, named by parameter, each
#'         with atima's `label` and `group` added.
#' @noRd
schema_params <- function (fn) {

  stopifnot(is_one_of(fn, names(schema_functions)))

  schema_once(paste0("params_", fn), {

    params <- rbiom_schema()[[fn]][['params']]
    params <- Filter(x = params, function (p) {
      !isTRUE(p[['r_only']]) && is.null(p[['deprecated']]) && !(p[['name']] %in% schema_hidden) })

    # A parameter that needs a package the server lacks cannot be used.
    params <- Filter(x = params, function (p) is.null(p[['needs']]) || has_package(p[['needs']]))

    names(params) <- vapply(params, function (p) p[['name']], character(1))

    unavailable <- schema_unavailable(fn)

    lapply(params, function (p) {

      name <- p[['name']]

      # Nor can a choice that needs one. What is left is what can be used,
      # so the browser has no use for the list of packages.
      if (!is.null(unavailable[[name]]))
        p[['choices']] <- Filter(x = p[['choices']], function (ch) {
          !((if (is.list(ch)) ch[['name']] else ch) %in% names(unavailable[[name]])) })

      p[['choices_needs']] <- NULL

      c(
        list(
          name  = name,
          label = if (name %in% names(schema_labels)) schema_labels[[name]] else name,
          group = if (name %in% schema_basic) "basic" else "advanced" ),
        p[setdiff(names(p), "name")] )
    })
  })
}


#______________________________________________________________________________
#' The image settings of a plot request, described like rbiom's parameters.
#' @noRd
save_params <- function () {
  list(
    device = list(
      name = "device", label = "File format", group = "basic", type = "choice",
      choices = list("png", "jpeg", "tiff", "bmp", "pdf", "svg", "eps", "ps"), max_n = 1L, default = "png",
      desc = "The image file format." ),
    width = list(
      name = "width", label = "Width", group = "basic", type = "number", max_n = 1L, default = 400,
      desc = "The image's width, in `units`." ),
    height = list(
      name = "height", label = "Height", group = "basic", type = "number", max_n = 1L, default = 300,
      desc = "The image's height, in `units`." ),
    units = list(
      name = "units", label = "Units", group = "basic", type = "choice",
      choices = list("px", "in", "cm", "mm"), max_n = 1L, default = "px",
      desc = "The units of `width` and `height`." ),
    dpi = list(
      name = "dpi", label = "Resolution", group = "advanced", type = "number", min = 30, max = 1200, max_n = 1L, default = 100,
      desc = "Dots per inch. With `units = \"px\"` it sets the size of text and lines relative to the image." ),
    scale = list(
      name = "scale", label = "Scale", group = "advanced", type = "number", min = 0.1, max = 10, max_n = 1L, default = 1,
      desc = "Multiplies the image's size without changing the size of text and lines." ) )
}

# The smallest and largest side an image may have, in pixels.
save_pixels <- c(50, 12000)


#______________________________________________________________________________
#' The schema the browser builds its controls from.
#'
#' It is the same for every project. Parameters whose choices depend on the
#' data say so with their `type` (`field`, `rank`, `taxa`, `metric`), and
#' the browser fills them in from the project summary it already has.
#' @return JSON text, of class `json`.
#' @noRd
browser_schema_json <- function () {

  schema_once("browser", {

    shown <- unlist(lapply(schema_browser_uses, schema_fns))
    shown <- intersect(names(schema_functions), shown)

    functions <- lapply(shown, function (fn) {
      entry <- rbiom_schema()[[fn]]
      c(
        list(fn = fn),
        schema_functions[[fn]],
        list(returns = entry[['returns']], sample_set = plot_sample_set(fn)),
        if (length(entry[['rules']]) > 0) list(rules = entry[['rules']]),
        list(params = unname(schema_params(fn))) )
    })
    names(functions) <- shown

    palettes <- list_palettes()
    palettes <- lapply(seq_len(nrow(palettes)), function (i) list(
      name   = palettes[['name']][[i]],
      kind   = palettes[['kind']][[i]],
      colors = as.list(palettes[['colors']][[i]]) ))

    schema <- list(
      rbiom     = as.character(packageVersion("rbiom")),
      hash      = rbiom_schema_hash(),
      functions = functions,
      palettes  = palettes,
      save      = list(
        params = unname(save_params()),
        pixels = list(min = save_pixels[[1]], max = save_pixels[[2]]) ),
      subset    = list(
        cat = "For each categorical field, the values to keep, in the order to show them.",
        num = "For each numeric field, the lowest and highest value to keep." ) )

    structure(class = "json", as.character(toJSON(schema, auto_unbox = TRUE, null = "null", digits = NA)))
  })
}


#' The schema route.
#' @noRd
api_schema <- function (REQ) {
  response(browser_schema_json(), headers = list('Cache-Control' = "private, max-age=300"))
}


#______________________________________________________________________________
#' What `rbiom::fn_check()` needs to know about a project, taken from its
#' summary.
#' @param summary  A project summary, from `biom_summary()`.
#' @return `list(fields = list(<name> = list(class)), ranks, tree)`
#' @noRd
summary_check_data <- function (summary) {

  fields        <- lapply(summary[['fields']], function (f) list(class = as.character(f[['class']])))
  names(fields) <- vapply(summary[['fields']], function (f) as.character(f[['name']]), character(1))

  list(
    fields = fields,
    ranks  = as.character(unlist(summary[['ranks']])),
    tree   = isTRUE(as.logical(summary[['tree']])) )
}


#______________________________________________________________________________
#' Check the parts of a function's arguments that do not depend on the data:
#' they are named, each names a parameter a remote caller may set, and each
#' value is plain data of a reasonable size.
#'
#' @param fn    The name of an exposed rbiom function.
#' @param args  The arguments, as they came out of the request's JSON.
#' @return The arguments, as a named list.
#' @noRd
check_fn_args_static <- function (fn, args) {

  if (is.null(args) || (is.list(args) && length(args) == 0)) return (list())

  if (!is.list(args) || is.data.frame(args))
    stop("must be a set of named options")

  keys <- names(args)
  if (is.null(keys) || anyNA(keys) || !all(nzchar(keys)) || anyDuplicated(keys))
    stop("must be a set of named options")

  params  <- schema_params(fn)
  unknown <- setdiff(keys, names(params))
  if (length(unknown) > 0)
    stop("has an option '", log_truncate(unknown[[1]], 40L), "' that ", fn, "() does not take")

  for (key in keys) {

    if (!is_plain_data(args[[key]]))
      stop("has an unusable value for '", key, "'")

    # A JSON object of single values is a named vector in R, e.g.
    # colors = c(Male = "blue", Female = "red").
    if (params[[key]][['type']] %in% c("aesthetic", "palette"))
      args[key] <- list(flatten_named(args[[key]]))
  }

  args
}


#' Is a value made only of strings, numbers, logicals, NULL and lists of
#' those, and small enough to be an argument?
#' @noRd
is_plain_data <- function (x, depth = 0L) {

  if (is.null(x))         return (TRUE)
  if (is.data.frame(x))   return (FALSE)
  if (length(x) > 5000L)  return (FALSE)

  if (is.list(x)) {
    if (depth >= 3L) return (FALSE)
    return (all(vapply(x, is_plain_data, logical(1), depth = depth + 1L)))
  }

  if (!is.null(dim(x)))   return (FALSE)
  if (is.character(x))    return (all(is.na(x) | nchar(x, type = "bytes") <= 500L))
  if (is.numeric(x))      return (all(is.na(x) | is.finite(x)))

  is.logical(x)
}


#' Turn a named list of single values into a named vector; leave anything
#' else as it is.
#' @noRd
flatten_named <- function (x) {

  if (!is.list(x) || length(x) == 0 || is.null(names(x))) return (x)

  single <- vapply(x, function (v) is.atomic(v) && length(v) == 1, logical(1))
  if (!all(single)) return (x)

  unlist(x)
}


#______________________________________________________________________________
#' Check a function's arguments against rbiom's description of the function
#' and against a project.
#'
#' @param fn       The name of an exposed rbiom function.
#' @param args     The arguments, as they came out of the request's JSON.
#' @param summary  The project's summary, from `biom_summary()`.
#' @return The arguments as rbiom will read them: names matched, values
#'         converted (`rank = 2` becomes `"Phylum"`, `layers = "xd"` becomes
#'         `c("box", "dot")`). Stops with rbiom's own message, which names
#'         the argument and the valid choices.
#' @noRd
check_fn_args <- function (fn, args, summary) {

  args <- check_fn_args_static(fn, args)

  args <- tryCatch(
    expr  = fn_check(fn, args, summary_check_data(summary)),
    error = function (e) stop("is not valid. ", plain_message(e), call. = FALSE) )

  # rbiom has matched the values to its choices; refuse the ones that need
  # a package this server does not have.
  unavailable <- schema_unavailable(fn)

  for (key in intersect(names(args), names(unavailable))) {
    asked <- intersect(as.character(unlist(args[[key]])), names(unavailable[[key]]))
    if (length(asked) > 0)
      stop(call. = FALSE, sprintf(
        "is not valid. `%s = \"%s\"` needs the %s package, which this server does not have",
        key, asked[[1]], unavailable[[key]][[asked[[1]]]] ))
  }

  args
}


#' An error's message on one line, without terminal colour codes, list
#' bullets or a final full stop.
#' @noRd
plain_message <- function (e) {
  msg <- gsub("\033\\[[0-9;]*[A-Za-z]", "", conditionMessage(e))
  msg <- gsub("[\u2716\u2139\u2022]", "", msg)
  msg <- trimws(gsub("[[:space:]]+", " ", msg))
  log_truncate(sub("\\.$", "", msg), 600L)
}


#______________________________________________________________________________
#' Check the image settings of a plot request, and fill in defaults.
#'
#' @param args  `list(device, width, height, units, dpi, scale)`, any of
#'              them left out.
#' @return A complete list of arguments for `ggsave()`.
#' @noRd
check_save_args <- function (args) {

  params <- save_params()

  if (is.null(args)) args <- list()

  if (!is.list(args) || is.data.frame(args) || (length(args) > 0 && is.null(names(args))) || anyDuplicated(names(args)))
    stop("must be a set of named image settings")

  unknown <- setdiff(names(args), names(params))
  if (length(unknown) > 0)
    stop("has an unknown image setting '", log_truncate(unknown[[1]], 40L), "'")

  clean <- list()

  for (key in names(params)) {

    param <- params[[key]]
    value <- args[[key]]

    if (is.null(value)) value <- param[['default']]

    if (param[['type']] == "choice") {
      if (!is_one_of(value, unlist(param[['choices']])))
        stop("has an image setting '", key, "' that is not one of: ", paste(param[['choices']], collapse = ", "))

    } else {
      if (is.character(value) && length(value) == 1 && grepl("^[0-9]+(\\.[0-9]+)?$", value))
        value <- as.numeric(value)
      if (!is.numeric(value) || length(value) != 1 || !is.finite(value) || value <= 0)
        stop("has an image setting '", key, "' that is not a positive number")
      if (!is.null(param[['min']]) && (value < param[['min']] || value > param[['max']]))
        stop("has an image setting '", key, "' outside ", param[['min']], " to ", param[['max']])
      value <- as.numeric(value)
    }

    clean[[key]] <- value
  }

  # The image's size in pixels, whatever the units.
  per_unit <- switch(clean[['units']], px = 1, `in` = clean[['dpi']], cm = clean[['dpi']] / 2.54, mm = clean[['dpi']] / 25.4)
  pixels   <- c(clean[['width']], clean[['height']]) * per_unit * clean[['scale']]

  if (any(pixels < save_pixels[[1]] | pixels > save_pixels[[2]]))
    stop("asks for an image that is not between ", save_pixels[[1]], " and ", save_pixels[[2]], " pixels on each side")

  clean
}


#______________________________________________________________________________
#' Check the sample filter of a plot request against a project.
#'
#' @param args     `list(cat = list(<field> = <values>), num = list(<field>
#'                 = c(lowest, highest)))`.
#' @param summary  The project's summary, or `NULL` to check the shape only.
#' @return `list(cat, num)` with only the parts that were given.
#' @noRd
check_subset_args <- function (args, summary = NULL) {

  if (is.null(args) || (is.list(args) && length(args) == 0)) return (list())

  if (!is.list(args) || is.data.frame(args) || is.null(names(args)) || anyDuplicated(names(args)) || !all(names(args) %in% c("cat", "num")))
    stop("must have only the parts 'cat' and 'num'")

  fields <- NULL
  if (!is.null(summary)) {
    fields        <- summary[['fields']]
    names(fields) <- vapply(fields, function (f) as.character(f[['name']]), character(1))
  }

  clean <- list()

  for (part in names(args)) {

    values <- args[[part]]
    if (is.null(values) || (is.list(values) && length(values) == 0)) next

    if (!is.list(values) || is.data.frame(values) || is.null(names(values)) || !all(nzchar(names(values))) || anyDuplicated(names(values)))
      stop("must name a metadata field for each filter")

    if (length(values) > 200L)
      stop("has too many filters")

    for (field in names(values)) {

      value <- values[[field]]
      shown <- log_truncate(field, 60L)

      if (!is.null(fields)) {
        if (!field %in% names(fields))
          stop("names a metadata field, '", shown, "', that this project does not have")
        kind <- as.character(fields[[field]][['class']])
        if (part == "cat" && kind != "categorical") stop("filters '", shown, "' by value, but it is numeric")
        if (part == "num" && kind != "numeric")     stop("filters '", shown, "' by range, but it is not numeric")
      }

      if (part == "cat") {

        if (is.list(value) && all(vapply(value, is_scalar_character, logical(1)))) value <- unlist(value)

        if (!is.character(value) || length(value) == 0 || length(value) > 5000L || anyNA(value) || anyDuplicated(value))
          stop("has unusable values for '", shown, "'")

        if (!is.null(fields) && !all(value %in% as.character(unlist(fields[[field]][['levels']]))))
          stop("has a value for '", shown, "' that is not in the data")

        value <- unname(value)

      } else {

        if (is.list(value) && all(vapply(value, function (v) is.numeric(v) && length(v) == 1, logical(1)))) value <- unlist(value)

        if (!is.numeric(value) || length(value) != 2 || !all(is.finite(value)) || value[[1]] > value[[2]])
          stop("needs a lowest and a highest value for '", shown, "'")

        value <- as.numeric(unname(value))
      }

      clean[[part]][[field]] <- value
    }
  }

  clean
}


#______________________________________________________________________________
#' A function's parameters as JSON Schema, the form tool definitions take.
#'
#' @param fn       The name of an exposed rbiom function.
#' @param summary  A project summary. With one, fields, ranks and metrics
#'                 are listed as the project has them; without, they are
#'                 described in words.
#' rbiom's rules about which parameters go together (exactly one of two, one
#' needed or not allowed with a given test) are written into the schema's
#' description, and into the schema itself where JSON Schema can say it.
#'
#' @return A list that `jsonlite::toJSON(auto_unbox = TRUE)` turns into a
#'         JSON Schema object.
#' @noRd
fn_json_schema <- function (fn, summary = NULL) {

  data   <- if (!is.null(summary)) summary_check_data(summary)
  params <- schema_params(fn)
  rules  <- fn_rules(fn)

  c(
    list(
      type                 = "object",
      description          = paste(c(paste0(schema_functions[[fn]][['label']], "."), rules_text(rules)), collapse = " "),
      properties           = lapply(params, param_json_schema, data = data),
      additionalProperties = FALSE ),
    rules_json_schema(rules) )
}


#' rbiom's rules for a function, without the ones that name a parameter this
#' server does not offer.
#' @noRd
fn_rules <- function (fn) {

  known <- names(schema_params(fn))

  Filter(x = rbiom_schema()[[fn]][['rules']], function (rule) {
    named <- unlist(c(
      rule[c("one_of", "any_of", "requires", "forbids")],
      lapply(rule[['when']], function (cond) cond[['param']]) ))
    all(named %in% known)
  })
}


#' One condition of a rule or of a parameter's `when`, in words.
#' @param cond  `list(param, is | is_not | has_any | is_null | not_null)`.
#' @noRd
condition_text <- function (cond) {

  name   <- paste0("`", cond[['param']], "`")
  values <- function (key) paste0('"', unlist(cond[[key]]), '"', collapse = " or ")

  if (!is.null(cond[['is']]))      return (paste(name, "is", values("is")))
  if (!is.null(cond[['is_not']]))  return (paste(name, "is not", values("is_not")))
  if (!is.null(cond[['has_any']])) return (paste(name, "includes", values("has_any")))
  if (isTRUE(cond[['is_null']]))   return (paste(name, "is not given"))
  if (isTRUE(cond[['not_null']]))  return (paste(name, "is given"))

  paste(name, "allows it")
}

#' Several conditions that must all hold, in words.
#' @noRd
conditions_text <- function (conds) {
  paste(vapply(conds, condition_text, character(1)), collapse = " and ")
}


#' A function's rules as sentences.
#' @return A character vector, one sentence per rule.
#' @noRd
rules_text <- function (rules) {

  ticked <- function (x) paste0("`", unlist(x), "`", collapse = ", ")

  unlist(lapply(rules, function (rule) {

    if (!is.null(rule[['one_of']])) return (paste0("Give exactly one of ", ticked(rule[['one_of']]), "."))
    if (!is.null(rule[['any_of']])) return (paste0("Give at least one of ", ticked(rule[['any_of']]), "."))

    when <- paste0("When ", conditions_text(rule[['when']]), ": ")

    c(
      if (!is.null(rule[['requires']])) paste0(when, ticked(rule[['requires']]), " must be given."),
      if (!is.null(rule[['forbids']]))  paste0(when, ticked(rule[['forbids']]), " cannot be used.") )
  }))
}


#' A function's rules as JSON Schema keywords, for the rules JSON Schema can
#' express: "one of", "any of", and "when a parameter has one of these
#' values, these are required (or not allowed)".
#' @return `list(allOf = ...)`, or an empty list.
#' @noRd
rules_json_schema <- function (rules) {

  required <- function (names) lapply(unlist(names), function (name) list(required = list(name)))

  parts <- lapply(rules, function (rule) {

    if (!is.null(rule[['one_of']])) return (list(oneOf = required(rule[['one_of']])))
    if (!is.null(rule[['any_of']])) return (list(anyOf = required(rule[['any_of']])))

    when <- rule[['when']]
    if (!all(vapply(when, function (cond) !is.null(cond[['is']]), logical(1)))) return (NULL)

    names <- vapply(when, function (cond) cond[['param']], character(1))
    test  <- lapply(when, function (cond) list(enum = as.list(unlist(cond[['is']]))))
    names(test) <- names

    list(
      `if`   = list(properties = test, required = as.list(names)),
      `then` = c(
        if (!is.null(rule[['requires']])) list(required = as.list(unlist(rule[['requires']]))),
        if (!is.null(rule[['forbids']]))  list(not = list(anyOf = required(rule[['forbids']]))) ))
  })

  parts <- Filter(length, parts)

  if (length(parts) == 0) list() else list(allOf = unname(parts))
}


#' One parameter as a JSON Schema property.
#' @noRd
param_json_schema <- function (p, data = NULL) {

  strings <- function (x) list(type = "string", enum = as.list(x))
  several <- function (item, max_n = NULL) c(
    list(type = "array", items = item),
    if (!is.null(max_n)) list(maxItems = max_n) )

  choices <- unlist(lapply(p[['choices']], function (ch) if (is.list(ch)) ch[['id']] %||% ch[['name']] else ch))
  limits  <- c(
    if (!is.null(p[['min']])) list(minimum = p[['min']]),
    if (!is.null(p[['max']]) && !identical(p[['max']], "Inf")) list(maximum = p[['max']]) )

  # What one value looks like, for each form the parameter accepts.
  form <- function (kind) switch(
    EXPR = kind,
    logical      = list(type = "boolean"),
    true         = list(const = TRUE),
    integer      = c(list(type = "integer"), limits),
    number       = c(list(type = "number"), limits),
    string       = list(type = "string"),
    choice       = strings(choices),
    palette      = list(type = "string", description = "The name of a color palette."),
    values       = several(list(type = c("string", "number"))),
    named_values = list(type = "object", additionalProperties = list(type = c("string", "number"))),
    count        = list(type = "integer", minimum = 1L),
    fraction     = list(type = "number", exclusiveMinimum = 0, exclusiveMaximum = 1),
    names        = several(list(type = "string")),
    fields       = several(field),
    spec         = list(type = "object"),
    list() )

  kind <- p[['class']] %||% "any"
  field <- list(type = "string", description = paste0(
    "The name of a ", if (kind != "any") paste0(kind, " "), "metadata field of the project." ))
  if (!is.null(data) && identical(p[['type']], "field")) {
    classes <- vapply(data[['fields']], function (f) f[['class']], character(1))
    keep    <- isTRUE(p[['coerce']]) | kind == "any" | classes == kind
    field   <- strings(names(classes)[keep])
  }

  base <- switch(
    EXPR = p[['type']],
    field     = field,
    rank      = if (is.null(data)) list(type = "string", description = "A taxonomic rank of the project.") else strings(data[['ranks']]),
    metric    = {
      ids <- choices
      if (!is.null(data) && !data[['tree']])
        ids <- unlist(lapply(p[['choices']], function (ch) if (!isTRUE(ch[['phylo']])) ch[['id']]))
      strings(ids)
    },
    layers    = strings(choices),
    choice    = strings(choices),
    logical   = form("logical"),
    integer   = form("integer"),
    number    = form("number"),
    string    = form("string"),
    NULL )

  max_n <- p[['max_n']]
  many  <- is.null(max_n) || max_n > 1 || isTRUE(p[['per_side']])

  # A parameter that lists its forms accepts exactly those; any other
  # accepts what its type says.
  forms   <- unlist(p[['forms']])
  options <- if (is.null(forms)) list(base) else lapply(forms, form)
  options <- Filter(length, options)

  # A rank can also be given by position: 1 is the first, -1 the last.
  if (identical(p[['type']], "rank")) options <- c(options, list(list(type = "integer")))

  if (many && !is.null(base) && (is.null(forms) || isTRUE(p[['per_side']])))
    options <- c(options, list(several(base, if (isTRUE(p[['per_side']])) 2L else max_n)))

  # Values a field parameter takes besides field names, such as ".taxa".
  if (!is.null(p[['extra']])) options <- c(options, list(strings(unlist(p[['extra']]))))

  if (!is.null(p[['null']])) options <- c(options, list(list(type = "null")))

  # Choices that depend on another parameter, and when this one matters.
  choices_when <- vapply(p[['choices_when']], FUN.VALUE = character(1), function (case) {
    paste0("When ", conditions_text(case[['when']]), ", the choices are: ", paste(unlist(case[['choices']]), collapse = ", "), ".") })

  description <- paste(c(
    paste0(p[['label']], ". ", p[['desc']]),
    p[['note']],
    if (!is.null(p[['null']])) paste("null:", p[['null']]),
    if (!is.null(p[['default_note']])) paste("Default:", p[['default_note']]),
    choices_when,
    if (length(p[['when']]) > 0) paste0("Only has an effect when ", conditions_text(p[['when']]), ".") ), collapse = " ")

  c(
    list(description = description),
    if (length(options) == 1) options[[1]][setdiff(names(options[[1]]), "description")] else list(anyOf = options),
    if (!is.null(p[['default']])) list(default = p[['default']]) )
}
