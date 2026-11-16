# The notes on choosing beside the controls (`js/guides.js`), and the
# example script for the MCP endpoint (`www/examples/atima_mcp.py`).

www <- function (...) system.file("www", ..., package = "atima")

read_text <- function (path) paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")

# guides.js is pure: it runs in V8 beside the browser's schema.
local_guides_js <- function () {

  testthat::skip_if_not_installed("V8")

  js  <- V8::v8()
  src <- read_text(www("js", "guides.js"))
  expect_no_match(src, "(^|\n)import ")
  js$eval(gsub("(^|\n)export ", "\\1", src))
  js$eval(paste0("const schema = ", browser_schema_json(), ";"))
  js
}


test_that("every note has a question, a few paragraphs and a link to rbiom's documentation", {

  js     <- local_guides_js()
  guides <- js$get("GUIDES", simplifyVector = FALSE)

  expect_setequal(names(guides), c("adiv", "bdiv", "depth", "ord", "test_groups", "test_trend", "test_distance", "test_mantel", "da"))

  for (key in names(guides)) {
    g <- guides[[key]]
    expect_match(g$title, "\\?$", info = key)
    expect_true(length(g$text) >= 2 && length(g$text) <= 6, info = key)
    for (p in g$text) expect_true(nchar(p) >= 40 && nchar(p) <= 700, info = paste(key, substr(p, 1, 40)))
    expect_match(g$more$href, "^https://cmmr\\.github\\.io/rbiom/reference/[a-z_]+\\.html$", info = key)
    expect_true(nzchar(g$more$label), info = key)

    # The page the link points to is one of rbiom's help pages.
    topic <- sub("\\.html$", "", basename(g$more$href))
    expect_true(length(utils::help(topic, package = "rbiom")) == 1, info = paste(key, topic))
  }
})


test_that("a note is beside every control it is about, by what the control is", {

  js <- local_guides_js()

  # Which parameter of which function gets which note.
  found <- js$get("
    Object.values(schema.functions).flatMap(def =>
      def.params.map(p => [def.fn, p.name, paramGuide(p)]).filter(x => x[2] !== null)
    ).map(x => x.join(' '))")

  expect_setequal(found, c(
    "adiv_boxplot adiv adiv", "adiv_corrplot adiv adiv", "rare_corrplot adiv adiv", "rare_multiplot adiv adiv",
    "bdiv_boxplot bdiv bdiv", "bdiv_corrplot bdiv bdiv", "bdiv_heatmap bdiv bdiv", "bdiv_ord_plot bdiv bdiv", "bdiv_clusters bdiv bdiv",
    "bdiv_ord_plot ord ord",
    "adiv_boxplot test test_groups", "taxa_boxplot test test_groups",
    "adiv_corrplot test test_trend", "taxa_corrplot test test_trend", "rare_corrplot test test_trend", "rare_multiplot test test_trend",
    "bdiv_boxplot test test_distance", "bdiv_ord_plot test test_distance",
    "bdiv_corrplot test test_mantel",
    "taxa_forest method da" ))

  # Every note but the depth's (beside the depth, on every plot page) is
  # beside some control.
  keys <- unique(sapply(strsplit(found, " "), `[[`, 3))
  expect_setequal(c(keys, "depth"), js$get("Object.keys(GUIDES)"))

  # The forest plot's note is also under its name, since its control is
  # under Advanced.
  expect_identical(js$get("Object.values(schema.functions).filter(def => functionGuide(def)).map(def => def.fn)"), "taxa_forest")
})


test_that("what the notes say of rbiom's defaults and controls is what rbiom and atima do", {

  js     <- local_guides_js()
  guides <- js$get("GUIDES", simplifyVector = FALSE)
  text   <- function (key) paste(unlist(guides[[key]]$text), collapse = " ")
  param  <- function (fn, name) schema_params(fn)[[name]]

  # The defaults the notes name.
  expect_identical(param("adiv_boxplot", "adiv")$default, "Shannon")
  expect_match(text("adiv"), "Shannon is the default")
  expect_identical(param("bdiv_ord_plot", "bdiv")$default, "bray")
  expect_match(text("bdiv"), "Bray-Curtis, the default")
  expect_identical(param("bdiv_ord_plot", "ord")$default, "PCoA")
  expect_match(text("ord"), "PCoA, the default")
  expect_identical(param("bdiv_ord_plot", "test")$default, "adonis2")
  expect_match(text("test_distance"), "PERMANOVA (adonis2), the default", fixed = TRUE)
  expect_identical(param("bdiv_ord_plot", "permutations")$default, 999L)
  expect_match(text("test_distance"), "0.001 with 999", fixed = TRUE)
  expect_identical(param("adiv_boxplot", "test")$default, "auto")
  expect_identical(param("taxa_forest", "method")$choices, list("linda"))

  # The counts each kind of figure is made from.
  for (fn in c("adiv_boxplot", "bdiv_ord_plot", "taxa_boxplot", "taxa_stacked")) expect_identical(plot_sample_set(fn), "rare", info = fn)
  for (fn in c("rare_corrplot", "rare_stacked", "rare_multiplot", "taxa_forest")) expect_identical(plot_sample_set(fn), "full", info = fn)
  expect_match(text("depth"), "The rarefaction figures and the differential abundance forest plot (LinDA) use all reads", fixed = TRUE)

  # The heuristic for an uploaded project's depth: the lowest depth that
  # keeps a tenth of all reads. Of 4,600 reads, a depth of 100 keeps 400
  # (four samples of 100), and 200 keeps 600.
  sums  <- c(100, 200, 300, 4000)
  depth <- rbiom::suggest_rarefy_depth(matrix(sums, nrow = 1, dimnames = list("otu", paste0("s", 1:4))))
  expect_identical(as.numeric(depth), 200)

  # Rarefying draws the same reads every time.
  expect_identical(rbiom::rarefy(rbiom::hmp50, depth = 500)$counts, rbiom::rarefy(rbiom::hmp50, depth = 500)$counts)

  # Every control a note names in quotes is one that atima shows, under
  # that label; "Reads per sample" is a page.
  quoted <- unique(gsub('"', "", unlist(regmatches(unlist(guides), gregexpr('"[^"]+"', unlist(guides))))))
  pages  <- vapply(schema_functions, function (f) f[['label']], character(1))
  expect_true(length(quoted) >= 8)
  for (q in quoted) expect_true(q %in% c(schema_labels, pages), info = q)
})


test_that("the notes open from the controls, the depth and the forest plot's heading", {

  controls <- read_text(www("js", "controls.js"))
  plot     <- read_text(www("js", "pages", "plot.js"))
  widgets  <- read_text(www("js", "widgets.js"))

  expect_match(controls, "guide: guideButton(paramGuide(p)),", fixed = TRUE)
  expect_match(plot, "depth.select, guideButton('depth'), device", fixed = TRUE)
  expect_match(read_text(www("js", "pages", "table.js")), "depth.select, guideButton('depth')", fixed = TRUE)
  expect_match(plot, "guideButton(functionGuide(def), { line: true })", fixed = TRUE)

  # The link to rbiom's documentation opens apart from the app.
  expect_match(widgets, "h('a', { href: g.more.href, target: '_blank', rel: 'noopener noreferrer' }, g.more.label)", fixed = TRUE)
})


test_that("the example script for the MCP endpoint is served and linked, and speaks what the server speaks", {

  path <- www("examples", "atima_mcp.py")
  expect_true(file.exists(path))
  src  <- read_text(path)

  # Linked from the home page, and from the article on AI apps.
  expect_match(read_text(www("js", "pages", "home.js")), "href: '/www/examples/atima_mcp.py', download: 'atima_mcp.py'", fixed = TRUE)
  article <- testthat::test_path("..", "..", "vignettes", "articles", "ai-apps.Rmd")
  if (file.exists(article))
    expect_match(read_text(article), "inst/www/examples/atima_mcp.py", fixed = TRUE)

  # Python's standard library only.
  imports <- unlist(regmatches(src, gregexpr("(?m)^(import|from) [A-Za-z0-9_.]+", src, perl = TRUE)))
  expect_setequal(sub("^(import|from) ", "", imports), c("argparse", "base64", "json", "sys", "urllib.error", "urllib.request"))

  # The protocol revision, and tools and arguments the server has.
  expect_match(src, sprintf('PROTOCOL = "%s"', mcp_versions[[1]]), fixed = TRUE)
  tools <- mcp_tool_table()
  for (tool in c("list_projects", "describe_project", "run_stats", "make_plot"))
    expect_match(src, sprintf('"%s"', tool), fixed = TRUE, info = tool)
  expect_true(all(c("project", "function", "args", "image") %in% names(tools[["make_plot"]][["args"]])))
  expect_true(all(c("adiv_stats", "bdiv_ord_plot") %in% names(schema_functions)))

  # It is valid Python, where Python can be found.
  python <- Sys.which(c("python3", "python"))
  python <- python[nzchar(python)]
  ok     <- FALSE
  for (exe in python) {
    out <- suppressWarnings(system2(exe, c("-I", "-c", shQuote("import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())"), shQuote(path)), stdout = TRUE, stderr = TRUE))
    if (is.null(attr(out, "status"))) { ok <- TRUE; break }
  }
  if (length(python) == 0 || !ok) skip("Python is not available here")
  expect_true(ok)
})
