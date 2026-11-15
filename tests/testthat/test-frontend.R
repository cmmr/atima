# The front end has no build step and no test runner of its own, so these
# tests read its files: that everything a page loads is shipped with the
# package, that nothing is fetched from another host, and that the few places
# where HTML is inserted stay few.

www <- function (...) system.file("www", ..., package = "atima")

read_text <- function (path) paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")

# Our own files, as paths relative to inst/www. `js/migration.js` is the old
# import code, kept only as the reference for renovation step 8.
own_files <- function (pattern) {
  files <- list.files(www(), pattern = pattern, recursive = TRUE)
  files[!startsWith(files, "assets/") & files != "js/migration.js"]
}

all_matches <- function (text, pattern) unlist(regmatches(text, gregexpr(pattern, text, perl = TRUE)))

# "js/pages" + "../dom.js" -> "js/dom.js"
resolve_import <- function (dir, import) {
  out <- character(0)
  for (part in strsplit(paste0(dir, "/", import), "/", fixed = TRUE)[[1]]) {
    if (part == "..")     out <- out[-length(out)]
    else if (part != ".") out <- c(out, part)
  }
  paste(out, collapse = "/")
}


test_that("the app's page is served with its version numbers and a strict policy", {

  REQ  <- local_test_req()
  resp <- handle_request(fake_request("GET", "/"), test_app(REQ))

  expect_identical(resp$status, 200L)
  expect_match(resp$headers[['Content-Type']], "text/html")
  expect_match(resp$body, as.character(packageVersion("atima")), fixed = TRUE)
  expect_no_match(resp$body, "{{", fixed = TRUE)

  # Nothing from another host, and no script written into the page.
  csp <- resp$headers[['Content-Security-Policy']]
  expect_match(csp, "default-src 'self'", fixed = TRUE)
  expect_match(csp, "script-src 'self'(;|$)")
  expect_no_match(csp, "unsafe")
  expect_no_match(resp$body, "<script(?![^>]*\\bsrc=)", perl = TRUE)
  expect_no_match(resp$body, "\\son[a-z]+\\s*=", perl = TRUE)

  # The same page for a project's address.
  expect_identical(handle_request(fake_request("GET", "/hmp50"), test_app(REQ))$body, resp$body)
})


test_that("a page address with parameters the server does not know still loads", {

  # Found in the browser (step 7): "/hmp50?r=1" answered 400 with a JSON
  # body. Links gather such parameters ("?utm_source=", "?fbclid=").
  REQ <- local_test_req()

  for (path in c("/", "/hmp50")) {
    resp <- handle_request(fake_request("GET", path, query = "?utm_source=mail&r=1"), test_app(REQ))
    expect_identical(resp$status, 200L, info = path)
    expect_match(resp$body, "<title>ATIMA</title>", fixed = TRUE)
  }

  # An address that cannot be a page is told so in HTML, not JSON.
  resp <- handle_request(fake_request("GET", paste0("/", strrep("a", 101))), test_app(REQ))
  expect_identical(resp$status, 400L)
  expect_match(resp$body, "^<!DOCTYPE html>")
})


test_that("every file the page and its scripts refer to is shipped", {

  index <- read_text(www("index.html"))
  refs  <- all_matches(index, '(?<=(src|href)=")/www/[^"]+')
  expect_gt(length(refs), 5)
  for (ref in refs)
    expect_true(file.exists(www(sub("^/www/", "", ref))), info = ref)

  # Paths written in scripts and styles ("/www/img/..."), except those put
  # together at run time.
  for (file in own_files("\\.(js|css)$")) {
    refs <- all_matches(read_text(www(file)), "/www/[A-Za-z0-9_./-]+\\.[a-z0-9]+(?=['\"`)])")
    for (ref in refs)
      expect_true(file.exists(www(sub("^/www/", "", ref))), info = paste(file, ref))
  }

  # The pictures of plotting symbols and fill patterns the controls offer.
  controls <- read_text(www("js", "controls.js"))
  patterns <- all_matches(sub("(?s).*const PATTERNS = \\[(.*?)\\];.*", "\\1", controls, perl = TRUE), "(?<=')[a-z0-9_]+(?=')")
  expect_gt(length(patterns), 20)
  expect_true(all(file.exists(www("img", "patterns", paste0(patterns, ".png")))))
  expect_true(all(file.exists(www("img", "shapes", paste0(0:18, ".png")))))
})


test_that("every script is a module that main.js reaches, and every import exists", {

  scripts <- own_files("\\.js$")
  reached <- character(0)
  queue   <- "js/main.js"

  while (length(queue) > 0) {
    file  <- queue[[1]]
    queue <- queue[-1]
    if (file %in% reached) next
    reached <- c(reached, file)

    expect_true(file.exists(www(file)), info = file)
    imports <- all_matches(read_text(www(file)), "(?<=from ')[^']+(?=')")
    for (import in imports) {
      expect_match(import, "^\\.{1,2}/", info = paste(file, "imports", import))
      queue <- c(queue, resolve_import(dirname(file), import))
    }
  }

  expect_setequal(reached, scripts)
})


test_that("every script is valid JavaScript", {

  # A script with a syntax error stops the whole app from starting, and
  # nothing else here would notice. V8 checks scripts, not modules, so the
  # import lines go and `export` is dropped from the declarations.
  testthat::skip_if_not_installed("V8")
  js <- V8::v8()

  for (file in own_files("\\.js$")) {
    lines <- readLines(www(file), warn = FALSE, encoding = "UTF-8")
    lines <- lines[!grepl("^import\\s.*\\sfrom\\s+'[^']+';\\s*$", lines)]
    lines <- sub("^export\\s+(default\\s+)?", "", lines)
    code  <- paste(c("async function module_body () {", lines, "}"), collapse = "\n")
    expect_true(js$validate(code), info = file)
  }

  # The check itself can tell a broken script from a sound one.
  expect_false(js$validate("const a = 'it's broken';"))
})


test_that("no page of the app asks another host for anything", {

  # Addresses of other hosts may only appear as links for people to follow.
  links <- c(
    "https://www.bcm.edu/",
    "https://www.bcm.edu/research/centers/metagenomics-and-microbiome-research",
    "https://cmmr.github.io/atima/",
    "https://cmmr.github.io/atima/articles/ai-apps.html",
    "https://github.com/cmmr/atima",
    "https://github.com/cmmr/rbiom",
    # On the administrators' Usage page: its documentation, and the credit
    # the licence of DB-IP's lookup files asks for.
    "https://cmmr.github.io/atima/articles/server.html#usage",
    "https://db-ip.com",
    # The name of the SVG namespace (js/charts.js). Nothing is fetched from it.
    "http://www.w3.org/2000/svg" )

  for (file in own_files("\\.(html|js|css)$")) {
    text  <- read_text(www(file))
    hosts <- all_matches(text, "https?://[A-Za-z0-9.-]+\\.[a-z]{2,}[^\\s'\"`)<]*")
    expect_true(all(hosts %in% links), info = paste(file, paste(setdiff(hosts, links), collapse = " ")))
    expect_no_match(text, "(src|href)\\s*[=:]\\s*['\"]//|url\\(\\s*['\"]?//", info = file)
  }

  # The vendored style sheets load their fonts from beside themselves.
  for (file in list.files(www("assets"), pattern = "\\.css$", recursive = TRUE)) {
    text <- read_text(www("assets", file))
    expect_no_match(text, "@import", info = file)
    expect_no_match(text, "url\\(\\s*['\"]?(https?:)?//", info = file)
  }
})


test_that("HTML is inserted in two places only, and nothing is evaluated", {

  inserts <- list()
  for (file in own_files("\\.js$")) {
    text <- read_text(www(file))
    n <- length(all_matches(text, "\\.(innerHTML|outerHTML)\\s*=[^=]"))
    if (n > 0) inserts[[file]] <- n
    expect_no_match(text, "insertAdjacentHTML|document\\.write|\\beval\\(|new Function\\(|setAttribute\\('on", info = file)
  }

  # serverHtml() in dom.js, and the table cells the server has escaped.
  expect_identical(inserts, list("js/dom.js" = 1L, "js/tables.js" = 1L))
})


test_that("the licence of every vendored library is recorded", {

  licences <- read_text(www("assets", "LICENSES.md"))
  for (entry in setdiff(list.files(www("assets")), "LICENSES.md"))
    expect_match(licences, entry, fixed = TRUE, info = entry)
})


test_that("navigation labels are short, and every control's label fits its line", {

  schema <- fromJSON(browser_schema_json(), simplifyVector = FALSE)

  # A function's link in the navigation: 12 characters at most, with the
  # full name as tooltip and page heading.
  for (fn in names(schema$functions)) {
    def <- schema$functions[[fn]]
    expect_true(is_scalar_character(def$short) && nzchar(def$short), info = fn)
    expect_lte(nchar(def$short), 12L)
    expect_gte(nchar(def$label), nchar(def$short))
  }

  # Two functions under one heading never share a name.
  areas <- vapply(schema$functions, function (def) paste(def$area, def$short), character(1))
  expect_identical(anyDuplicated(areas), 0L)

  # The links written in main.js: navLink('#/page', 'Label', ...).
  main   <- read_text(www("js", "main.js"))
  labels <- all_matches(main, "(?<=navLink\\('#/[a-z]{1,20}', ')[^']+(?=')")
  expect_gte(length(labels), 8)
  expect_true(all(c("Import", "Privacy", "Cite") %in% labels))
  labels <- c(labels, all_matches(main, "(?<=navOutside\\([A-Z_]{1,20}, ')[^']+(?=')"))
  expect_true(all(c("Docs", "GitHub") %in% labels))
  expect_true(all(nchar(labels) <= 12L), info = paste(labels[nchar(labels) > 12L], collapse = ", "))

  # Headings of the groups of links may be a little longer.
  headings <- all_matches(read_text(www("js", "schema.js")), "(?<=: ')[A-Z][a-z]+ ?[a-z]*(?=')")
  expect_true(all(c("Alpha diversity", "Taxa abundance") %in% headings))
  expect_true(all(nchar(headings) <= 15L))

  # A control is one line, label left and value right: 16 characters at most.
  labels <- unique(c(
    unlist(lapply(schema$functions, function (def) vapply(def$params, function (p) p$label, character(1)))),
    vapply(schema$save$params, function (p) p$label, character(1)) ))
  labels <- labels[labels %in% c(schema_labels, vapply(schema$save$params, function (p) p$label, character(1)))]
  expect_gt(length(labels), 50)
  expect_true(all(nchar(labels) <= 16L), info = paste(labels[nchar(labels) > 16L], collapse = ", "))
})


test_that("no page or script writes a style or a script into the page", {

  # The Content-Security-Policy forbids both, so they would silently not apply.
  for (file in own_files("\\.html$")) {
    text <- read_text(www(file))
    expect_no_match(text, "<style|\\sstyle\\s*=", info = file)
    expect_no_match(text, "\\son[a-z]+\\s*=", perl = TRUE, info = file)
  }

  # Scripts set styles through `element.style`, which the policy allows,
  # never by writing a style attribute or a style element.
  for (file in own_files("\\.js$")) {
    text <- read_text(www(file))
    expect_no_match(text, "setAttribute\\(\\s*['\"]style|cssText|createElement\\(\\s*['\"]style|h\\('style", info = file)
    expect_no_match(text, "style=\\\\?['\"]", info = file)
  }
})


# `js/schema.js` is pure: no page, no imports. So it can be run here, in
# V8, with the real schema and a real project summary.
local_schema_js <- function (env = parent.frame()) {

  testthat::skip_if_not_installed("V8")

  js <- V8::v8()
  src <- read_text(www("js", "schema.js"))
  expect_no_match(src, "(^|\n)import ")
  js$eval(gsub("(^|\n)export ", "\\1", src))

  summary <- biom_summary(rbiom::hmp50, rbiom::rarefy(rbiom::hmp50))
  js$eval(paste0("const schema = ", browser_schema_json(), ";"))
  js$eval(paste0("const biom = ", toJSON(summary, null = "null", digits = NA), ";"))
  js$eval("const F = schema.functions; const P = (fn, name) => param(F[fn], name);")
  js
}


test_that("a control's value is shared between plots of the same kind of parameter", {

  js <- local_schema_js()

  # The same key wherever the parameter is the same kind.
  expect_true(js$get("shareKey(P('adiv_boxplot', 'stat.by')) === shareKey(P('taxa_boxplot', 'stat.by'))"))
  expect_true(js$get("shareKey(P('adiv_boxplot', 'stat.by')) === shareKey(P('bdiv_ord_plot', 'stat.by'))"))
  expect_true(js$get("shareKey(P('adiv_boxplot', 'stat.by')) === shareKey(P('bdiv_boxplot', 'stat.by'))"))
  expect_true(js$get("shareKey(P('adiv_boxplot', 'p.adj')) === shareKey(P('taxa_corrplot', 'p.adj'))"))
  expect_true(js$get("shareKey(P('adiv_boxplot', 'layers')) === shareKey(P('taxa_boxplot', 'layers'))"))

  # A different key where the name is the same and the thing is not: a
  # categorical and a numeric x, the layers and the tests of different plots.
  expect_false(js$get("shareKey(P('adiv_boxplot', 'x')) === shareKey(P('adiv_corrplot', 'x'))"))
  expect_false(js$get("shareKey(P('adiv_boxplot', 'layers')) === shareKey(P('bdiv_ord_plot', 'layers'))"))
  expect_false(js$get("shareKey(P('adiv_boxplot', 'test')) === shareKey(P('adiv_corrplot', 'test'))"))
  expect_false(js$get("shareKey(P('adiv_boxplot', 'colors')) === shareKey(P('taxa_stacked', 'colors'))"))

  # Within one function no two parameters share a key.
  expect_true(js$get("Object.values(F).every(def => new Set(def.params.map(shareKey)).size === def.params.length)"))

  # What is set on one plot is there on the next.
  js$eval("
    let shared = {};
    const put = (fn, name, value) => { shared[shareKey(P(fn, name))] = value; };
    const args = fn => fnArgs(F[fn], shared, biom);
    put('adiv_boxplot', 'x', 'Body Site');
    put('adiv_boxplot', 'stat.by', 'Sex');
    put('adiv_boxplot', 'p.adj', 'bonferroni');
    put('adiv_boxplot', 'layers', ['bar', 'dot']);
    put('adiv_boxplot', 'colors', { Female: '#aa3377', Male: '#4477aa' });")

  expect_identical(js$get("args('taxa_boxplot')['stat.by']"), "Sex")
  expect_identical(js$get("args('bdiv_ord_plot')['stat.by']"), "Sex")
  expect_identical(js$get("args('taxa_corrplot')['p.adj']"), "bonferroni")
  expect_identical(js$get("args('taxa_boxplot').layers.join()"), "bar,dot")
  expect_identical(js$get("args('taxa_boxplot').colors.Male"), "#4477aa")
  expect_identical(js$get("JSON.stringify(payload(F.taxa_boxplot, args('taxa_boxplot')).x)"), '"Body Site"')

  # It applies only where it is valid: a categorical field is no x for a
  # correlation, box plot layers are not an ordination's, and a function
  # without the parameter is not touched.
  expect_false(js$get("'x' in args('adiv_corrplot')"))
  expect_false(js$get("'layers' in args('bdiv_ord_plot')"))
  expect_identical(js$get("JSON.stringify(args('rare_stacked'))"), "{}")
  expect_identical(js$get("JSON.stringify(args('taxa_heatmap'))"), "{}")

  # Colors named for the groups of a field go with that field. In the beta
  # diversity plots the groups are pairs that only rbiom works out.
  expect_false(js$get("'colors' in args('bdiv_boxplot')"))
  expect_identical(js$get("args('bdiv_boxplot')['stat.by']"), "Sex")
  js$eval("put('adiv_boxplot', 'stat.by', 'Body Site');")
  expect_false(js$get("'colors' in args('adiv_boxplot')"))
  js$eval("put('adiv_boxplot', 'stat.by', 'Sex');")
  expect_true(js$get("'colors' in args('adiv_boxplot')"))          # and comes back

  # Comparing within groups is the beta diversity plots' alone.
  js$eval("put('bdiv_boxplot', 'stat.by', '==Sex');")
  expect_identical(js$get("args('bdiv_boxplot')['stat.by']"), "==Sex")
  expect_false(js$get("'stat.by' in args('adiv_boxplot')"))
  js$eval("put('adiv_boxplot', 'stat.by', 'Sex');")

  # Nothing set, nothing sent, for every function.
  expect_true(js$get("Object.values(F).every(def => Object.keys(fnArgs(def, {}, biom)).length === 0)"))
})


test_that("shared values follow the open project", {

  js <- local_schema_js()

  js$eval("
    const key = (fn, name) => shareKey(P(fn, name));
    const shared = {
      [key('adiv_boxplot', 'stat.by')]: 'Sex',
      [key('adiv_boxplot', 'facet.by')]: ['Body Site'],
      [key('adiv_boxplot', 'colors')]: { Female: '#aa3377', Male: '#4477aa' },
      [key('adiv_boxplot', 'p.adj')]: 'bonferroni',
      [key('taxa_boxplot', 'rank')]: 'Genus',
      [key('adiv_boxplot', 'adiv')]: ['faith'],
      [key('adiv_corrplot', 'x')]: 'Age' };")

  # The same project: nothing to drop, and the same object comes back.
  expect_true(js$get("pruneShared(schema, shared, biom) === shared"))

  # A project without the field Sex, without a tree, and with other ranks.
  js$eval("
    const other = { ...biom, tree: false, ranks: ['.otu', 'Phylum'],
      fields: biom.fields.filter(f => f.name !== 'Sex') };
    const left = pruneShared(schema, shared, other);")

  expect_false(js$get("key('adiv_boxplot', 'stat.by') in left"))
  expect_false(js$get("key('adiv_boxplot', 'colors') in left"))
  expect_false(js$get("key('taxa_boxplot', 'rank') in left"))
  expect_false(js$get("key('adiv_boxplot', 'adiv') in left"))       # Faith's needs a tree
  expect_true(js$get("key('adiv_boxplot', 'facet.by') in left"))
  expect_true(js$get("key('adiv_boxplot', 'p.adj') in left"))
  expect_true(js$get("key('adiv_corrplot', 'x') in left"))
})


test_that("a control with no effect says why", {

  js <- local_schema_js()

  # Shapes need a layer of points; the default box plot has none.
  js$eval("const eff = effective(F.adiv_boxplot, {});")
  expect_false(js$get("active(P('adiv_boxplot', 'shapes'), F.adiv_boxplot, eff)"))
  expect_identical(
    js$get("inactiveReason(P('adiv_boxplot', 'shapes'), F.adiv_boxplot, eff)"),
    'Has no effect unless "Layers" includes dot, strip or pointrange.' )
  expect_identical(js$get("inactiveReason(P('adiv_boxplot', 'colors'), F.adiv_boxplot, eff)"), "")

  # Colors, shapes and patterns sit under the parameter whose values they are given to.
  expect_identical(js$get("parentOf(P('adiv_boxplot', 'colors'), F.adiv_boxplot)"), "stat.by")
  expect_identical(js$get("parentOf(P('taxa_stacked', 'colors'), F.taxa_stacked)"), "taxa")
  expect_true(js$get("parentOf(P('taxa_forest', 'colors'), F.taxa_forest) === null"))
  expect_true(js$get("parentOf(P('adiv_boxplot', 'test'), F.adiv_boxplot) === null"))
})



test_that("a number box's arrows move by an amount that suits the number", {

  js <- local_schema_js()

  step <- function (fn, name) js$get(sprintf("numberStep(P('%s', '%s'))", fn, name))

  # A share or a probability: hundredths.
  expect_equal(step("adiv_boxplot", "level"),   0.01)
  expect_equal(step("adiv_boxplot", "p.label"), 0.01)
  expect_equal(step("taxa_forest",  "p.sig"),   0.01)

  # Whole numbers by one; other numbers by a tenth of their default's size.
  expect_equal(step("bdiv_boxplot", "permutations"), 1)
  expect_equal(step("bdiv_clusters", "k"),           1)
  expect_equal(step("taxa_heatmap", "asp"),          0.1)
  expect_equal(step("taxa_heatmap", "tree_height"),  1)

  # The image settings: 10 for a width of 400, 0.1 for a scale of 1.
  js$eval("const save = name => schema.save.params.find(p => p.name === name);")
  expect_equal(js$get("numberStep(save('width'))"),  10)
  expect_equal(js$get("numberStep(save('height'))"), 10)
  expect_equal(js$get("numberStep(save('dpi'))"),    10)
  expect_equal(js$get("numberStep(save('scale'))"),  0.1)

  # No default to go by: one.
  expect_equal(step("adiv_corrplot", "mu"), 1)
  expect_equal(step("taxa_boxplot", "p.top"), 1)
})


# `js/render.js` is pure too: it decides what the plot page shows while a
# figure is drawn, waits to be drawn, or is older than its settings.
local_render_js <- function () {

  testthat::skip_if_not_installed("V8")

  js  <- V8::v8()
  src <- read_text(www("js", "render.js"))
  expect_no_match(src, "(^|\n)import ")
  js$eval(gsub("(^|\n)export ", "\\1", src))
  js$eval("const V = (o) => view({ auto: true, busy: false, drawn: true, stale: false, complete: true, message: false, ...o });")
  js
}


test_that("with 're-render automatically' ticked the plot page behaves as before", {

  js <- local_render_js()

  # A change of a control draws the figure again.
  expect_identical(js$get("onChange(true)"), "draw")

  # Nothing in progress: no box, the figure as it is, Download allowed.
  v <- js$get("V({})")
  expect_identical(v$box, "hidden")
  expect_null(v$button)
  expect_false(v$dim)
  expect_true(v$download)
  expect_false(v$note)

  # While a figure is drawn: the box in the middle, with Stop.
  v <- js$get("V({ busy: true })")
  expect_identical(v$box, "center")
  expect_identical(v$button, "stop")
  expect_true(v$dim)
  expect_true(v$download)

  # Settings to complete: no Download.
  expect_false(js$get("V({ complete: false, drawn: false, message: true })")$download)
})


test_that("unticked, a figure is drawn on request and an older one is marked", {

  js <- local_render_js()

  # A change of a control does not draw.
  expect_identical(js$get("onChange(false)"), "mark")

  # A page just opened waits for Render.
  v <- js$get("V({ auto: false, drawn: false })")
  expect_identical(v$box, "center")
  expect_identical(v$heading, "Not drawn yet")
  expect_identical(v$button, "render")
  expect_true(v$canRender)
  expect_false(v$download)

  # The figure is older than its settings: said so, greyed, no Download,
  # and the statistics and the code say so too.
  v <- js$get("V({ auto: false, stale: true })")
  expect_identical(v$box, "center")
  expect_identical(v$heading, "Settings changed")
  expect_identical(v$button, "render")
  expect_true(v$dim)
  expect_false(v$download)
  expect_true(v$note)

  # The figure matches its settings: the box steps aside, Download is back.
  v <- js$get("V({ auto: false })")
  expect_identical(v$box, "corner")
  expect_identical(v$button, "render")
  expect_false(v$dim)
  expect_true(v$download)
  expect_false(v$note)

  # While it is drawn the button is Stop, and the old figure cannot be
  # downloaded as if it were the new one.
  v <- js$get("V({ auto: false, busy: true, stale: true })")
  expect_identical(v$button, "stop")
  expect_false(v$download)

  # Settings to complete, or an error on screen: the box leaves the message
  # readable, and Render is only there for settings that can be drawn.
  v <- js$get("V({ auto: false, complete: false, message: true })")
  expect_identical(v$box, "corner")
  expect_false(v$canRender)
  expect_false(v$download)
  v <- js$get("V({ auto: false, drawn: false, message: true })")
  expect_identical(v$box, "corner")
  expect_true(v$canRender)
})


test_that("a figure is older than its settings only while they differ", {

  js <- local_render_js()

  expect_false(js$get("isStale(null, 'a')"))     # nothing drawn yet
  expect_false(js$get("isStale('a', 'a')"))
  expect_true(js$get("isStale('a', 'b')"))       # a control changed ...
  expect_false(js$get("isStale('a', 'a')"))      # ... and was put back
})


test_that("the choice to draw on request is remembered, and survives a browser without storage", {

  js <- local_render_js()

  js$eval("
    const box = {}; const storage = { getItem: k => (k in box ? box[k] : null), setItem: (k, v) => { box[k] = v; } };
    const broken = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); } };")

  # Ticked unless the user said otherwise.
  expect_true(js$get("readAuto(storage)"))
  js$eval("writeAuto(storage, false);")
  expect_false(js$get("readAuto(storage)"))
  js$eval("writeAuto(storage, true);")
  expect_true(js$get("readAuto(storage)"))

  # No storage: ticked, and nothing throws.
  expect_true(js$get("readAuto(broken)"))
  expect_silent(js$eval("writeAuto(broken, false);"))
})


test_that("the plot page keeps its render control reachable and labelled", {

  src <- read_text(www("js", "pages", "plot.js"))

  # The checkbox has a label, the box a name, and what it says is announced.
  expect_match(src, "label.render-auto', { for: autoId", fixed = TRUE)
  expect_match(src, "'Re-render automatically'", fixed = TRUE)
  expect_match(src, "role: 'group', 'aria-label': 'Drawing the figure'", fixed = TRUE)
  expect_match(src, "div.render-status', { role: 'status' }", fixed = TRUE)

  # Every change of a control goes through the one place that decides
  # between drawing and marking: only it and draw() touch the timer.
  expect_length(all_matches(src, "(?<![.\\w])schedule\\(\\)"), 1L)
})
