# The schema: what atima exposes of rbiom, the route that serves it, and the
# checks made on a request's arguments before any worker is used.


# A request that must be answered without a worker.
expect_no_worker <- function (code) {
  with_mocked_bindings(code, worker_run = function (...) stop("a worker was used"))
}

# All parameters rbiom describes for the functions atima exposes.
rbiom_params <- function (fn) rbiom::fn_schema(fn)$params
param_names  <- function (params) vapply(params, function (p) p$name, character(1))


# The registry against rbiom ---------------------------------------------------

test_that("every exposed function and parameter is one rbiom has", {

  exported <- getNamespaceExports("rbiom")
  covered  <- names(rbiom::fn_schema())

  expect_true(all(names(schema_functions) %in% exported))
  expect_true(all(names(schema_functions) %in% covered))
  expect_true(all(vapply(schema_functions, function (f) f$use, "") %in% c("plot", "clusters")))

  exposed <- character(0)

  for (fn in names(schema_functions)) {

    params  <- schema_params(fn)
    formals <- names(formals(getExportedValue("rbiom", fn)))

    # Nothing is offered that the function does not take.
    expect_true(all(names(params) %in% formals), info = fn)

    # Nothing is offered that only an R caller may set, or that is deprecated.
    expect_false(any(c("biom", "tree", "cpus", "...", "weighted", "normalized", "file", "clone") %in% names(params)), info = fn)
    for (p in rbiom_params(fn))
      if (isTRUE(p$r_only) || !is.null(p$deprecated))
        expect_false(p$name %in% names(params), info = paste(fn, p$name))

    # Each has what a control needs.
    for (p in params) {
      expect_true(is_scalar_character(p$label) && nzchar(p$label), info = paste(fn, p$name))
      expect_true(p$group %in% c("basic", "advanced"), info = paste(fn, p$name))
      expect_true(is_scalar_character(p$type), info = paste(fn, p$name))
      expect_true(is_scalar_character(p$desc) && nzchar(p$desc), info = paste(fn, p$name))
    }

    # A plot function returns a plot, a clustering function a factor.
    returns <- rbiom::fn_schema(fn)$returns$type
    expect_identical(returns, switch(schema_functions[[fn]]$use, plot = "plot", clusters = "factor"), info = fn)

    # (Whatever the server has installed: a parameter that needs a package
    # it lacks is left out of `params`, but it still exists.)
    exposed <- union(exposed, param_names(Filter(function (p) !isTRUE(p$r_only) && is.null(p$deprecated), rbiom_params(fn))))
  }

  # atima's own tables name only parameters that exist.
  expect_identical(setdiff(names(schema_labels), exposed), character(0))
  expect_identical(setdiff(schema_basic, exposed), character(0))
  expect_identical(anyDuplicated(names(schema_labels)), 0L)

  all_params <- unique(unlist(lapply(names(schema_functions), function (fn) param_names(rbiom_params(fn)))))
  expect_true(all(schema_hidden %in% all_params))
})


test_that("what rbiom has and atima does not yet cover is reported", {

  exposed <- unique(unlist(lapply(names(schema_functions), function (fn) names(schema_params(fn)))))

  # Parameters shown under their own name for want of a label.
  unlabelled <- setdiff(exposed, names(schema_labels))
  if (length(unlabelled) > 0)
    message("rbiom parameters without an atima label: ", paste(unlabelled, collapse = ", "))

  # Functions rbiom describes that no route offers.
  covered <- rbiom::fn_schema()
  unused  <- setdiff(names(covered), names(schema_functions))
  plots   <- unused[vapply(covered[unused], function (e) e$returns$type == "plot", logical(1))]
  if (length(plots) > 0)
    message("rbiom plot functions atima does not expose: ", paste(plots, collapse = ", "))

  # Parameters atima hides on purpose.
  if (length(schema_hidden) > 0)
    message("rbiom parameters atima hides: ", paste(schema_hidden, collapse = ", "))

  # Every parameter of rbiom 4.0.0 has a label; a newer rbiom may add some.
  expect_true(all(c("x", "transform", "p.adj", "strata", "permutations", "seed", "alpha", "unc", "lineage") %in% names(schema_labels)))
})


# The route --------------------------------------------------------------------

test_that("the schema route serves every exposed function to anyone", {

  REQ  <- local_test_req()
  resp <- expect_no_worker(handle_request(fake_request("POST", "/api/schema", list()), test_app(REQ)))

  expect_identical(resp$status, 200L)
  expect_match(resp$headers[['Content-Type']], "application/json")

  schema <- response_json(resp)
  expect_named(schema, c("rbiom", "functions", "palettes", "save", "subset"))
  expect_identical(schema$rbiom, as.character(utils::packageVersion("rbiom")))
  expect_setequal(names(schema$functions), names(schema_functions))

  box <- schema$functions$adiv_boxplot
  expect_identical(box[c("fn", "use", "area", "label")], list(fn = "adiv_boxplot", use = "plot", area = "alpha", label = "Alpha diversity box plot"))
  expect_identical(box$returns$type, "plot")

  params <- box$params
  names(params) <- param_names(params)
  expect_false(any(c("biom", "cpus", "...") %in% names(params)))

  # A field: its choices come from the project, so only its kind is here.
  expect_identical(
    params$x[c("label", "group", "type", "class", "max_n")],
    list(label = "X axis", group = "basic", type = "field", class = "categorical", max_n = 1L) )
  expect_true("default" %in% names(params$x))
  expect_null(params$x$default)

  # Limits, choices and defaults are rbiom's.
  expect_identical(params$level[c("group", "type", "min", "max", "default")], list(group = "advanced", type = "number", min = 0.5, max = 1L, default = 0.95))
  expect_identical(unlist(params$transform$choices), c("none", "rank", "log", "log1p", "sqrt"))
  expect_identical(params$p.adj$default, formals(rbiom::adiv_boxplot)$p.adj)
  expect_true("fdr" %in% unlist(params$p.adj$choices))
  expect_identical(params$layers$choices[[1]], list(letter = "x", name = "box"))
  expect_true("faith" %in% vapply(params$adiv$choices, function (m) m$id, ""))

  # A choice list of one is still a list, and when a parameter has any
  # effect comes along.
  forest <- schema$functions$taxa_forest
  method <- Filter(function (p) p$name == "method", forest$params)[[1]]
  expect_identical(method$choices, list("linda"))
  expect_identical(forest$rules, list(list(one_of = list("stat.by", "regr"))))
  expect_true(is.list(params$shapes$when) && params$shapes$when[[1]]$param == "layers")

  # The lists the old summary carried are here now.
  ord <- Filter(function (p) p$name == "ord", schema$functions$bdiv_ord_plot$params)[[1]]
  expect_identical(unlist(ord$choices), c("PCoA", "tSNE", "NMDS", "UMAP"))
  clust <- Filter(function (p) p$name == "clust", schema$functions$taxa_heatmap$params)[[1]]
  expect_true(all(c("ward.D", "ward.D2", "complete") %in% unlist(clust$choices)))

  # Palettes and image settings.
  expect_true(all(c("name", "kind", "colors") %in% names(schema$palettes[[1]])))
  expect_true("okabe" %in% vapply(schema$palettes, function (p) p$name, ""))
  expect_identical(param_names(schema$save$params), c("device", "width", "height", "units", "dpi", "scale"))

  # It is a POST like every API route, and takes no arguments.
  expect_identical(handle_request(fake_request("POST", "/api/schema", list(fn = "x")), test_app(REQ))$status, 400L)
})


# Checks that need no project ---------------------------------------------------

test_that("image settings are checked and completed", {

  expect_identical(check_save_args(NULL), list(device = "png", width = 400, height = 300, units = "px", dpi = 100, scale = 1))
  expect_identical(
    check_save_args(list(height = 4L, device = "pdf", units = "in", width = "6.5")),
    list(device = "pdf", width = 6.5, height = 4, units = "in", dpi = 100, scale = 1) )

  bad <- list(
    list(device = "exe"), list(device = "wmf"), list(device = c("png", "pdf")), list(units = "furlongs"),
    list(width = 0), list(width = -5), list(width = "wide"), list(width = c(1, 2)), list(width = NA), list(width = Inf),
    list(width = 100000), list(width = 10), list(width = 60, units = "in"), list(dpi = 5), list(dpi = 5000),
    list(scale = 100), list(filename = "/etc/passwd"), list(path = "x"), list(limitsize = FALSE), list(bg = "red"),
    list(1), "png", list(width = list(1)) )

  for (args in bad)
    expect_error(check_save_args(args), info = paste(deparse(args), collapse = ""))
})


test_that("the parts of a function's arguments that need no project are checked", {

  ok  <- function (args, fn = "adiv_boxplot") check_fn_args_static(fn, args)
  bad <- function (args, pattern, fn = "adiv_boxplot") expect_error(check_fn_args_static(fn, args), pattern, info = paste(deparse(args), collapse = ""))

  expect_identical(ok(NULL), list())
  expect_identical(ok(list()), list())
  expect_identical(ok(list(x = "Sex", level = 0.9)), list(x = "Sex", level = 0.9))
  expect_identical(ok(list(x = NULL)), list(x = NULL))

  # A JSON object of single values becomes a named vector.
  expect_identical(ok(list(colors = list(Male = "blue", Female = "red")))$colors, c(Male = "blue", Female = "red"))

  bad("x",                         "named options")
  bad(list("Sex"),                 "named options")
  bad(list(x = "a", x = "b"),      "named options")
  bad(data.frame(x = "Sex"),       "named options")
  bad(list(cpus = 8),              "option 'cpus' that adiv_boxplot\\(\\) does not take")
  bad(list(biom = "x"),            "does not take")
  bad(list(tree = "x"),            "does not take", fn = "bdiv_boxplot")
  bad(list(weighted = FALSE),      "does not take", fn = "bdiv_boxplot")
  bad(list(labs.title = "x"),      "does not take")
  bad(list(`...` = "x"),           "does not take")
  bad(list(bogus = 1),             "does not take")
  bad(list(dist = "euclidean"),    "does not take")   # a parameter of another function
  bad(list(x = function () 1),     "unusable value")
  bad(list(x = data.frame(a = 1)), "unusable value")
  bad(list(x = strrep("a", 600)),  "unusable value")
  bad(list(x = list(list(list(list(1))))), "unusable value")
  bad(list(mu = Inf),              "unusable value", fn = "adiv_corrplot")
})


test_that("each function's parameters can be given as JSON Schema", {

  s <- biom_summary(rbiom::hmp50, rbiom::rarefy(rbiom::hmp50))

  for (fn in names(schema_functions)) {

    plain  <- fn_json_schema(fn)
    filled <- fn_json_schema(fn, s)

    expect_identical(plain$type, "object", info = fn)
    expect_false(plain$additionalProperties, info = fn)
    expect_identical(names(plain$properties), names(schema_params(fn)), info = fn)

    for (name in names(plain$properties)) {
      p <- plain$properties[[name]]
      expect_true(is_scalar_character(p$description) && nzchar(p$description), info = paste(fn, name))
      expect_true(any(c("type", "anyOf", "enum", "const") %in% names(p)), info = paste(fn, name))
    }

    # It is JSON: no functions, and it survives a round trip.
    json <- jsonlite::toJSON(filled, auto_unbox = TRUE, null = "null")
    expect_identical(names(jsonlite::fromJSON(json, simplifyVector = FALSE)$properties), names(filled$properties), info = fn)
  }

  box <- fn_json_schema("adiv_boxplot", s)$properties
  expect_identical(box$level[c("type", "minimum", "maximum", "default")], list(type = "number", minimum = 0.5, maximum = 1L, default = 0.95))
  expect_identical(box$test$enum, list("auto", "none", "wilcox", "emmeans", "kruskal"))
  expect_identical(box$x$anyOf[[1]]$enum, list(".sample", "Age", "BMI", "Body Site", "Sex"))
  expect_identical(box$x$anyOf[[2]], list(type = "null"))

  # Without a project, a field is described; with one that has no tree,
  # the metrics that need one are left out.
  expect_match(fn_json_schema("adiv_boxplot")$properties$x$anyOf[[1]]$description, "categorical metadata field")
  s$tree <- FALSE
  expect_false("faith" %in% unlist(fn_json_schema("adiv_boxplot", s)$properties$adiv$anyOf[[1]]$enum))
})


# Checks against the open project, in the router --------------------------------

test_that("bad plot requests are refused before a worker is used", {

  s    <- local_open_project()
  plot <- function (plot_args = list(x = "Sex"), ..., plot_fn = "adiv_boxplot")
    s$post("/api/plot", list(plot_fn = plot_fn, plot_args = plot_args, depth = 1183, ...))

  local_mocked_bindings(worker_run = function (...) stop("a worker was used"))

  refused <- function (resp, pattern) {
    expect_identical(resp$status, 400L, info = pattern)
    expect_match(response_json(resp)$error$message, pattern)
  }

  # An unknown parameter, and the ones a browser must not set.
  refused(plot(list(bogus = 1)),                  "^Argument 'plot_args' has an option 'bogus' that adiv_boxplot\\(\\) does not take\\.$")
  refused(plot(list(x = "Sex", cpus = 64)),       "option 'cpus'")
  refused(plot(list(biom = "/etc/passwd")),       "option 'biom'")
  refused(plot(list(tree = "x"), plot_fn = "bdiv_boxplot"), "option 'tree'")
  refused(plot(list(weighted = TRUE), plot_fn = "bdiv_boxplot"), "option 'weighted'")
  refused(plot(list(labs.title = "<b>x</b>")),    "option 'labs.title'")

  # Out of range, wrong type, not in the list.
  refused(plot(list(level = 3)),                  "`level` must be between 0.5 and 1")
  refused(plot(list(level = "high")),             "`level` must be numeric")
  refused(plot(list(test = "adonis2")),           "Invalid `test` option")
  refused(plot(list(transform = "percent")),      "Invalid `transform` option")
  refused(plot(list(p.adj = "bonferoni-ish")),    "Invalid `p.adj` option")
  refused(plot(list(layers = "q")),               "layers")
  refused(plot(list(adiv = "nosuch")),            "does not match any option")
  refused(plot(list(permutations = 0), plot_fn = "bdiv_boxplot"), "permutations")
  refused(plot(list(flip = "yes")),               "flip")

  # Not in the project.
  refused(plot(list(x = "No Such Field")),        "Invalid `x` option\\(s\\): No Such Field")
  refused(plot(list(x = "Age", stat.by = "Nope")), "stat.by")
  refused(plot(list(rank = "Species"), plot_fn = "taxa_heatmap"), "rank")
  refused(plot(list(), plot_fn = "taxa_forest"),  "stat.by")

  # A function atima does not expose, however its arguments look.
  refused(plot(plot_fn = "taxa_da"),              "^Argument 'plot_fn' is not one of the allowed values")
  refused(plot(plot_fn = "write_xlsx"),           "plot_fn")

  # Image settings and the sample filter.
  refused(plot(save_args = list(device = "exe")),                        "^Argument 'save_args' has an image setting 'device'")
  refused(plot(save_args = list(width = 1e6)),                           "pixels")
  refused(plot(save_args = list(filename = "x")),                        "unknown image setting")
  refused(plot(subset_args = list(cat = list(Nope = "x"))),              "^Argument 'subset_args' names a metadata field, 'Nope'")
  refused(plot(subset_args = list(cat = list(Sex = "Other"))),           "not in the data")
  refused(plot(subset_args = list(cat = list(Age = "21"))),              "numeric")
  refused(plot(subset_args = list(num = list(Sex = c(1, 2)))),           "not numeric")
  refused(plot(subset_args = list(num = list(Age = c(1, 2, 3)))),        "lowest and a highest")
  refused(plot(subset_args = list(num = list(Age = c(40, 20)))),         "lowest and a highest")
  refused(plot(subset_args = list(rows = 1:3)),                          "'cat' and 'num'")

  # The error is JSON text, whatever the request put in it.
  resp <- plot(list(x = "<script>alert(1)</script>"))
  expect_match(resp$headers[['Content-Type']], "application/json")
  expect_match(response_json(resp)$error$message, "<script>alert(1)</script>", fixed = TRUE)
})


test_that("the handler gets the arguments as rbiom reads them", {

  s    <- local_open_project()
  seen <- NULL
  local_mocked_bindings(call_handler = function (route, REQ, args) { seen <<- args; list(ok = TRUE) })

  resp <- s$post("/api/plot", list(
    plot_fn     = "bdiv_boxplot",
    plot_args   = list(x = "==Sex", bdiv = "Bray", layers = "xd", colors = list(Male = "blue", Female = "red"), stat.by = "Sex"),
    depth       = 1183,
    save_args   = list(device = "pdf", width = 6, height = 4, units = "in"),
    subset_args = list(cat = list(`Body Site` = list("Stool", "Saliva")), num = list(Age = c(20L, 40L))) ))
  expect_identical(resp$status, 200L)

  expect_identical(seen$plot_args$x, "Sex")
  expect_identical(seen$plot_args$within, "Sex")
  expect_identical(seen$plot_args$bdiv, "bray")
  expect_identical(seen$plot_args$layers, c("box", "dot"))
  expect_identical(seen$plot_args$colors, c(Male = "blue", Female = "red"))
  expect_identical(seen$save_args, list(device = "pdf", width = 6, height = 4, units = "in", dpi = 100, scale = 1))
  expect_identical(seen$subset_args, list(cat = list(`Body Site` = c("Stool", "Saliva")), num = list(Age = c(20, 40))))
})


test_that("every exposed plot function draws through the worker path", {

  s <- local_open_project()

  requests <- list(
    adiv_boxplot   = list(x = "Body Site", adiv = c("Shannon", "Simpson"), layers = "xd", transform = "rank", p.adj = "holm"),
    adiv_corrplot  = list(x = "Age", stat.by = "Sex", test = "emtrends", fit = "lm"),
    bdiv_boxplot   = list(x = "==Body Site", bdiv = "jaccard", permutations = 99, seed = 1),
    bdiv_corrplot  = list(x = "Age", bdiv = "bray", permutations = 99),
    bdiv_heatmap   = list(bdiv = "unweighted_unifrac", tracks = c("Body Site", "Age"), clust = "ward.D2"),
    bdiv_ord_plot  = list(bdiv = "generalized_unifrac", alpha = 0.3, ord = "PCoA", stat.by = "Body Site", strata = "Sex", permutations = 99),
    rare_corrplot  = list(adiv = "Observed", stat.by = "Body Site"),
    rare_stacked   = list(rline = 1000, y.transform = "none"),
    rare_multiplot = list(),
    taxa_boxplot   = list(x = "Body Site", rank = "Phylum", taxa = 3, unc = "drop"),
    taxa_corrplot  = list(x = "Age", rank = "Phylum", taxa = 2, lineage = TRUE),
    taxa_heatmap   = list(rank = "Genus", taxa = 10, tracks = "Body Site", rescale = "rows"),
    taxa_stacked   = list(rank = "Phylum", taxa = 5, order.by = "Body Site", unc = "grouped"),
    taxa_forest    = list(stat.by = "Sex", rank = "Genus", lineage = FALSE, p.top = 10) )

  expect_setequal(names(requests), schema_fns("plot"))

  for (plot_fn in names(requests)) {

    resp <- s$post("/api/plot", list(plot_fn = plot_fn, plot_args = requests[[plot_fn]], depth = 1183, attrs = TRUE))
    expect_identical(resp$status, 200L, info = paste(plot_fn, resp$body))
    if (resp$status != 200L) next

    body  <- response_json(resp)
    image <- file.path(s$temp, basename(body$image_url))
    expect_identical(readBin(image, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)), info = plot_fn)
    expect_match(body$code$rbiom, plot_fn, info = plot_fn)

    # The rarefaction plots are drawn from the counts before rarefying.
    expect_identical(body$code$file, paste0("hmp50/", if (startsWith(plot_fn, "rare_")) "full" else "rare", ".json"), info = plot_fn)
  }

  # An image with no room for its figure is the request's fault. (Whether
  # a figure fits depends on fonts and packages, so the device's complaint
  # is simulated.)
  resp <- with_mocked_bindings(
    ggsave = function (...) stop("Viewport has zero dimension(s)"),
    code   = s$post("/api/plot", list(plot_fn = "rare_stacked", plot_args = list(), depth = 1183, save_args = list(width = 60, height = 60, dpi = 300))) )
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "^The image is too small for this figure")
  expect_length(list.files(s$temp, pattern = "\\.tmp$", recursive = TRUE), 0)

  # taxa_forest's statistics are taxa_da()'s table.
  resp <- s$post("/api/plot", list(plot_fn = "taxa_forest", plot_args = list(stat.by = "Sex"), depth = 1183, attrs = TRUE))
  body <- response_json(resp)
  expect_true(length(body$stats_table) > 0)
  expect_true(all(c("taxa", "lfc", "adj_p") %in% names(body$stats_table[[1]])))
  expect_match(body$code$stats, "taxa_da")
})


test_that("a worker makes the checks when the main process has no summary", {

  s    <- local_open_project()
  memo <- s$REQ$MEMO
  plot <- function (plot_args, ...) s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = plot_args, depth = 1183, ...))
  forget <- function () rm(list = ls(memo), envir = memo)

  expect_length(ls(memo), 1)

  # As after a restart: what needs no project is still refused at once ...
  forget()
  resp <- expect_no_worker(plot(list(cpus = 4)))
  expect_identical(resp$status, 400L)
  expect_length(ls(memo), 0)

  # ... the rest is refused by the worker, in the same words ...
  resp <- plot(list(x = "No Such Field"))
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "^Argument 'plot_args' is not valid\\. Invalid `x` option")

  resp <- plot(list(x = "Sex"), subset_args = list(cat = list(Sex = "Other")))
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "^Argument 'subset_args' has a value for 'Sex'")

  # ... and a good request is drawn, after which the summary is known again.
  resp <- plot(list(x = "==Sex", layers = "xd"))
  expect_identical(resp$status, 400L)   # `==` is for beta diversity only
  resp <- plot(list(x = "Sex", layers = "xd"))
  expect_identical(resp$status, 200L)
  expect_null(response_json(resp)$BIOM)
  expect_length(ls(memo), 1)

  resp <- expect_no_worker(plot(list(x = "No Such Field")))
  expect_identical(resp$status, 400L)
})


# Exports -----------------------------------------------------------------------

test_that("export methods and ranks are rbiom's and the project's", {

  s      <- local_open_project()
  export <- function (...) s$post("/api/project/export", list(...))

  bad <- expect_no_worker(list(
    export(what = "taxa", rank = "Species"),
    export(what = "taxa", rank = "../../etc"),
    export(what = "beta", method = "nosuch"),
    export(what = "beta", method = "Bray-Curtis") ))
  expect_identical(vapply(bad, function (r) r$status, 1L), rep(400L, 4))
  expect_match(response_json(bad[[1]])$error$message, "^Argument 'rank' is not a rank of this project\\.$")

  rare <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")
  full <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE public_key = 'hmp50'", "T2")
  base <- paste0("/tmp/", s$session$session_key, "/")
  url  <- function (...) { resp <- export(...); expect_identical(resp$status, 200L); response_json(resp)$download_url }

  expect_identical(url(what = "beta", method = "unweighted_unifrac"), sprintf("%s%i/beta_unweighted_unifrac_rare_%i.csv", base, rare, rare))
  expect_identical(url(what = "taxa", rank = "Phylum"), sprintf("%s%i/taxa_Phylum_full_%i.csv", base, full, full))

  # The OTU rank's name is not a file name; the file is named after it anyway.
  expect_match(url(what = "taxa"), sprintf("^%s%i/taxa_otu[0-9a-f]{8}_full_%i\\.csv$", base, full, full))
  expect_identical(url(what = "taxa", rank = "otu"), url(what = "taxa", rank = ".otu"))
})


test_that("a project can be exported as an Excel workbook", {

  skip_if_not_installed("openxlsx")

  s    <- local_open_project()
  resp <- s$post("/api/project/export", list(what = "xlsx"))
  expect_identical(resp$status, 200L)

  url  <- response_json(resp)$download_url
  rare <- db_query(s$DB, "SELECT rare_bf_id FROM projects WHERE public_key = 'hmp50'", "T1")
  full <- db_query(s$DB, "SELECT full_bf_id FROM projects WHERE public_key = 'hmp50'", "T2")
  expect_identical(url, sprintf("/tmp/%s/%i/xlsx_rare_%i_%i.xlsx", s$session$session_key, full, rare, full))

  file   <- file.path(s$REQ$CONFIG$temp_dir, sub("^/tmp/", "", url))
  sheets <- openxlsx::getSheetNames(file)
  expect_true(all(c("Sample Metadata", "Alpha Diversity", "OTU Taxonomy", "Rarefied OTU Counts") %in% sheets))

  # The rarefied sheets are at the depth on screen.
  counts <- openxlsx::read.xlsx(file, sheet = "Rarefied OTU Counts")
  sums   <- colSums(counts[, vapply(counts, is.numeric, logical(1)), drop = FALSE])
  expect_true(all(sums == 1183))
  expect_length(list.files(s$temp, pattern = "\\.tmp$", recursive = TRUE), 0)
})


# Clusters ----------------------------------------------------------------------

test_that("clusters are added to the working copy as a categorical field", {

  s   <- local_open_project()
  add <- function (...) s$post("/api/metadata/add_clusters", list(...))

  # Bad requests never reach a worker.
  bad <- expect_no_worker(list(
    add(cluster_fn = "taxa_clusters", name = "Groups", cluster_args = list(k = 0)),
    add(cluster_fn = "taxa_clusters", name = "Groups", cluster_args = list(k = 2.5)),
    add(cluster_fn = "taxa_clusters", name = "Groups", cluster_args = list(rank = "Species")),
    add(cluster_fn = "taxa_clusters", name = "Groups", cluster_args = list(bdiv = "bray")),
    add(cluster_fn = "bdiv_clusters", name = "Groups", cluster_args = list(cpus = 16)),
    add(cluster_fn = "bdiv_clusters", name = "Groups", cluster_args = list(bdiv = "nosuch")),
    add(cluster_fn = "taxa_clusters", name = "<b>Groups</b>"),
    add(cluster_fn = "taxa_clusters", name = ".sample"),
    add(cluster_fn = "adiv_boxplot",  name = "Groups") ))
  expect_identical(vapply(bad, function (r) r$status, 1L), rep(400L, length(bad)))

  resp <- add(cluster_fn = "taxa_clusters", name = "Taxa groups", cluster_args = list(rank = "Genus", k = 3))
  expect_identical(resp$status, 200L)
  BIOM <- response_json(resp)$BIOM
  expect_identical(field_names(BIOM), c(".sample", "Age", "BMI", "Body Site", "Sex", "Taxa groups"))
  expect_identical(BIOM$fields[[6]], list(name = "Taxa groups", class = "categorical", levels = list("Cluster 1", "Cluster 2", "Cluster 3")))
  expect_identical(BIOM$depth, 1183L)
  expect_false(BIOM$is_saved)

  resp <- add(cluster_fn = "bdiv_clusters", name = "UniFrac groups", cluster_args = list(bdiv = "weighted_unifrac", k = 4))
  expect_identical(resp$status, 200L)
  expect_length(response_json(resp)$BIOM$fields[[7]]$levels, 4)

  # A name can be used once, whatever its case.
  resp <- add(cluster_fn = "taxa_clusters", name = "taxa GROUPS")
  expect_identical(resp$status, 400L)
  expect_match(response_json(resp)$error$message, "already has a metadata field")

  # The new field works like any other, and the saved project is untouched.
  resp <- s$post("/api/plot", list(
    plot_fn = "bdiv_ord_plot", plot_args = list(stat.by = "Taxa groups", permutations = 99), depth = 1183,
    subset_args = list(cat = list(`Taxa groups` = c("Cluster 1", "Cluster 2"))) ))
  expect_identical(resp$status, 200L)

  hmp50 <- db_query(s$DB, "SELECT meta_colnames FROM projects WHERE public_key = 'hmp50'", "T1")
  expect_no_match(hmp50, "groups")
})


# Counts that are not whole numbers ---------------------------------------------

test_that("relative abundances are refused until the user agrees to scaling", {

  s <- local_open_project()

  file <- withr::local_tempfile(fileext = ".biom")
  biom <- rbiom::biom_relativize(rbiom::hmp50)
  biom$tree <- NULL
  rbiom::write_biom(biom, file)

  n_projects <- function () db_query(s$DB, "SELECT COUNT(*) FROM projects", "T1")
  before     <- n_projects()

  # Without the go-ahead: an error the browser can recognise, and nothing kept.
  resp <- s$upload(file, "relative.biom")
  expect_identical(resp$status, 400L)
  error <- response_json(resp)$error
  expect_named(error, c("message", "id", "code"))
  expect_identical(error$code, "confirm_inflate")
  expect_match(error$message, "not whole numbers")
  expect_identical(n_projects(), before)

  # Other errors carry no code.
  expect_named(response_json(s$post("/api/plot", list(plot_fn = "nope", plot_args = list(), depth = 1)))$error, c("message", "id"))

  # With it: a project like any other.
  resp <- s$upload(file, "relative.biom", inflate = "true")
  expect_identical(resp$status, 200L)
  BIOM <- response_json(resp)$BIOM
  expect_identical(BIOM$title, "relative")
  expect_false(BIOM$tree)
  expect_true(BIOM$depth >= 1L)
  expect_identical(n_projects(), before + 1L)

  resp <- s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(x = "Body Site"), depth = BIOM$depth))
  expect_identical(resp$status, 200L)

  # This project has no tree: metrics that need one are refused up front.
  bad <- expect_no_worker(list(
    s$post("/api/plot", list(plot_fn = "adiv_boxplot", plot_args = list(adiv = "faith"), depth = BIOM$depth)),
    s$post("/api/project/export", list(what = "beta", method = "weighted_unifrac")) ))
  expect_identical(vapply(bad, function (r) r$status, 1L), c(400L, 400L))
  expect_match(response_json(bad[[2]])$error$message, "^Argument 'method' needs a phylogenetic tree")

  # Whole-number counts are never touched, with or without the flag.
  counts <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(rbiom::hmp50, counts)
  resp <- s$upload(counts, "counts.biom", inflate = "true")
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$BIOM$depth, 1183L)
})
