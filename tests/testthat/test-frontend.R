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

  # The template files the upload buttons point to (test-import.R reads
  # them).
  templates <- unique(unlist(lapply(own_files("\\.js$"), function (file) {
    all_matches(read_text(www(file)), "[a-z-]+-template\\.[a-z]+") })))
  expect_setequal(templates, list.files(www("templates")))
  expect_length(templates, 2)
})


test_that("what can be uploaded is said beside the upload buttons, with the limit", {

  actions <- read_text(www("js", "actions.js"))

  # One text, for the pages that have an upload button.
  help <- sub("(?s).*export function uploadHelp\\(\\) \\{(.*?)\n\\}.*", "\\1", actions, perl = TRUE)
  for (word in c("BIOM", "QIIME 2", ".qza", "mothur", ".shared", "tab- or comma-separated", "maxUploadMb()", "Templates"))
    expect_match(help, word, fixed = TRUE)

  for (page in c("home.js", "projects.js"))
    expect_match(read_text(www("js", "pages", page)), "uploadHelp()", fixed = TRUE)

  # The limit is the server's, and a file over it is not sent.
  expect_match(actions, "store.get('conf').max_upload_mb", fixed = TRUE)
  expect_match(actions, "if (!file || tooLarge(file)) return;", fixed = TRUE)

  # No page still says that only BIOM files are taken.
  for (file in own_files("\\.(js|css)$"))
    expect_no_match(read_text(www(file)), "Upload a BIOM file|Drop a BIOM file")
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
    # rbiom's help pages, linked from the notes on choosing (js/guides.js).
    "https://cmmr.github.io/rbiom/reference/",
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

  # The functions with a page of their own kind are among them, and each
  # kind of page is one main.js can show: the link is "#/<use>/<function>".
  expect_true(all(c("taxa_upset", "taxa_top", "taxa_shared") %in% names(schema$functions)))
  uses <- unique(vapply(schema$functions, function (def) def$use, character(1)))
  expect_setequal(uses, schema_browser_uses)
  main <- read_text(www("js", "main.js"))
  for (use in uses)
    expect_match(main, sprintf("\n  %s:\\s+\\{ show: ", use), info = use)
  expect_match(main, "navLink(`#/${f.use}/${f.fn}`", fixed = TRUE)

  # The table page has the plot page's depth control.
  expect_match(read_text(www("js", "pages", "table.js")), "depthControl()", fixed = TRUE)

  # The sample names are offered as groups where rbiom's note on the
  # parameter says what ".sample" does there (schema.js, fieldChoices()):
  # taxa_top's `by`, the top taxa of each sample.
  by <- Filter(function (p) p$name == "by", schema$functions$taxa_top$params)[[1]]
  expect_identical(by$class, "categorical")
  expect_match(by$note, '".sample"', fixed = TRUE)
  expect_match(read_text(www("js", "schema.js")), '/"\\.sample"/.test(p.note', fixed = TRUE)

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
  expect_identical(v$button, "render")
  expect_false(v$canRender)
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

  # The figure matches its settings: the box goes, Download is back, and
  # there is nothing to render.
  v <- js$get("V({ auto: false })")
  expect_identical(v$box, "hidden")
  expect_identical(v$button, "render")
  expect_false(v$canRender)
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
  expect_identical(v$box, "hidden")
  expect_false(v$canRender)
  expect_false(v$download)
  v <- js$get("V({ auto: false, drawn: false, message: true })")
  expect_identical(v$box, "hidden")
  expect_true(v$canRender)
})


test_that("the render box stays while the user is at it, and is never anywhere but the middle", {

  js <- local_render_js()

  # The figure has arrived and the mouse is still over the box: it stays,
  # with the checkbox, and the figure is no longer greyed.
  v <- js$get("V({ held: true })")
  expect_identical(v$box, "held")
  expect_identical(v$heading, "The figure is up to date")
  expect_identical(v$button, "render")
  expect_false(v$canRender)
  expect_false(v$dim)
  expect_true(v$download)

  # Drawing on request, it keeps its Render button meanwhile, switched
  # off: the figure is up to date.
  v <- js$get("V({ auto: false, held: true })")
  expect_identical(v$box, "held")
  expect_identical(v$button, "render")
  expect_false(v$canRender)

  # Being at the box changes nothing while it has something to say.
  expect_identical(js$get("V({ busy: true, held: true })"), js$get("V({ busy: true })"))
  expect_identical(js$get("V({ auto: false, stale: true, held: true })"), js$get("V({ auto: false, stale: true })"))

  # No situation puts it in a corner, and it always has its button:
  # Stop while a figure is drawn, Render otherwise.
  js$eval("
    const boxes = new Set(); let buttons = true;
    for (let i = 0; i < 128; i++) {
      const bit = n => Boolean(i >> n & 1);
      const v = view({ auto: bit(0), busy: bit(1), drawn: bit(2), stale: bit(3), complete: bit(4), message: bit(5), held: bit(6) });
      boxes.add(v.box);
      if (v.button !== (bit(1) ? 'stop' : 'render')) buttons = false;
    }")
  expect_setequal(js$get("[...boxes]"), c("hidden", "center", "held"))
  expect_true(js$get("buttons"))

  # Ticked, Render is of use after Stop only: the figure is not the settings'.
  expect_true(js$get("V({ stale: true, held: true })")$canRender)
  expect_true(js$get("V({ drawn: false, held: true })")$canRender)
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


test_that("the line under a figure does not repeat the figure's caption", {

  src <- read_text(www("js", "pages", "plot.js"))

  # rbiom's caption, in the image, says which counts the figure was made
  # from. The page reads it to those who cannot see the image, and adds
  # only the sample filter and which way a fold change points. Only where
  # rbiom wrote no caption (taxa_upset) does the line say what the figure
  # was made from (`madeFrom()` in schema.js, which the table page uses).
  expect_no_match(src, "rarefied to|before rarefying")
  expect_match(src, "const made = resp.caption ? '' : S.madeFrom(def, biom);", fixed = TRUE)
  expect_match(src, "img.alt = [`${def.label}.`, resp.caption || made]", fixed = TRUE)
  expect_match(src, "sample filter", fixed = TRUE)
})


# `js/address.js` is pure as well: the page's address, and a figure's
# settings in it.
local_address_js <- function () {

  testthat::skip_if_not_installed("V8")

  js  <- V8::v8()
  src <- read_text(www("js", "address.js"))
  expect_no_match(src, "(^|\n)import ")
  js$eval(gsub("(^|\n)export ", "\\1", src))
  js
}


test_that("a figure's settings go into the page's address and come back the same", {

  js <- local_address_js()

  js$eval("
    const state = {
      a: { x: 'Body Site', 'stat.by': 'Sex', layers: ['bar', 'dot'], colors: { Female: '#aa3377', Male: '#4477aa' }, 'facet.by': null, level: 0.9 },
      s: { cat: { 'Body Site': ['Saliva', 'Stool'] }, num: { Age: [21, 30.5] } },
      v: { width: 800, units: 'px' }, f: false, d: 1183 };
    const text = encodeState(state);")

  # Only letters an address may hold after #, and nothing a route splits on.
  expect_match(js$get("text"), "^[A-Za-z0-9_-]+$")
  expect_true(js$get("JSON.stringify(decodeState(text)) === JSON.stringify(state)"))

  # R's NULL is a value ('no facets'): it is kept inside the arguments.
  expect_true(js$get("decodeState(text).a['facet.by'] === null"))

  # Any text survives: other scripts, quotes, the characters of a path.
  js$eval("const odd = { a: { x: 'K\\u00f6rpergr\\u00f6\\u00dfe (cm) / \\u201cGr\\u00f6\\u00dfe\\u201d \\u8eab\\u9577 \\ud83d\\ude00', taxa: ['a/b', 'c?d#e'] } };")
  expect_true(js$get("JSON.stringify(decodeState(encodeState(odd))) === JSON.stringify(odd)"))
  expect_match(js$get("encodeState(odd)"), "^[A-Za-z0-9_-]+$")
  for (n in 0:7)
    expect_true(js$get(sprintf("decodeState(encodeState({ a: { t: 'x'.repeat(%i) } })).a.t.length === %i", n, n)))

  # Every setting at its default: nothing to keep, and the address is the page's alone.
  expect_identical(js$get("encodeState({ a: {}, s: null, v: {}, f: null, d: null })"), "")
  expect_identical(js$get("buildHash('plot', 'adiv_boxplot', encodeState({ a: {} }))"), "#/plot/adiv_boxplot")
  expect_identical(js$get("buildHash('home')"), "#/home")

  # Too much to keep (a colour by hand for each of very many groups): the page alone.
  expect_identical(js$get("encodeState({ a: { colors: Object.fromEntries(Array.from({ length: 2000 }, (_, i) => ['group ' + i, '#123456'])) } })"), "")

  # The address apart and together again.
  js$eval("const hash = buildHash('plot', 'bdiv_ord_plot', text); const back = parseHash(hash);")
  expect_identical(js$get("hash.split('/').length"), 4L)
  expect_identical(js$get("[back.page, back.arg]"), c("plot", "bdiv_ord_plot"))
  expect_true(js$get("back.state === text"))
  expect_identical(js$get("JSON.stringify(parseHash('#/plot/adiv_boxplot'))"), '{"page":"plot","arg":"adiv_boxplot","state":null}')
  expect_identical(js$get("JSON.stringify(parseHash(''))"), '{"page":"home","arg":null,"state":null}')
  expect_identical(js$get("parseHash('#/plot/%E0%A4%A')['arg']"), "%E0%A4%A")       # not an escape: left as it is
})


test_that("an address that someone cut short or wrote by hand does no harm", {

  js <- local_address_js()

  # Not settings at all: read as none.
  for (text in c("", "!!!", "abc", "eyJhIjp7", "bnVsbA", "WzEsMl0", "MTIz"))
    expect_true(js$get(sprintf("decodeState('%s') === null", text)), info = text)
  expect_true(js$get("decodeState(null) === null"))
  expect_true(js$get("decodeState('A'.repeat(STATE_MAX + 1)) === null"))

  # Settings of the wrong shape are dropped one by one; the rest stays.
  js$eval("
    const c = cleanState({
      a: { x: 'Sex' },
      s: { cat: { Sex: ['Male'], Bad: 'Male', Empty: [], Mixed: ['a', 1] }, num: { Age: [20, 30], Up: [30, 20], One: [1], Text: ['a', 'b'] } },
      v: { width: 800, units: 'in', height: -1, dpi: null, scale: { a: 1 } },
      f: 'no', d: 1183.5 });")
  expect_identical(js$get("JSON.stringify(c.args)"), '{"x":"Sex"}')
  expect_identical(js$get("JSON.stringify(c.subset)"), '{"cat":{"Sex":["Male"]},"num":{"Age":[20,30]}}')
  expect_identical(js$get("JSON.stringify(c.save)"), '{"width":800,"units":"in"}')
  expect_true(js$get("c.fit"))
  expect_true(js$get("c.depth === null"))

  expect_false(js$get("cleanState({ f: false }).fit"))
  expect_identical(js$get("cleanState({ d: 1183 }).depth"), 1183L)

  # Nothing, or nonsense, is every setting at its default.
  for (x in c("null", "undefined", "'text'", "[1, 2]", "{ a: [1], s: 'x', v: 3 }"))
    expect_identical(
      js$get(sprintf("JSON.stringify(cleanState(%s))", x)),
      '{"args":{},"subset":{"cat":{},"num":{}},"save":{},"fit":true,"depth":null}', info = x )
})


test_that("the settings an address restores are checked against the function and the project", {

  # What the address carries goes through the same door as what the user
  # sets by hand: `fnArgs()` keeps only what suits the function and the
  # open project.
  js <- local_schema_js()

  js$eval("
    let shared = {};
    const put = (fn, name, value) => { shared[shareKey(P(fn, name))] = value; };
    put('adiv_boxplot', 'x', 'No Such Field');
    put('adiv_boxplot', 'stat.by', 'Sex');
    put('adiv_boxplot', 'adiv', ['nonsense']);
    put('adiv_boxplot', 'level', 'high');
    put('adiv_boxplot', 'layers', ['<img src=x onerror=alert(1)>']);")

  expect_identical(js$get("JSON.stringify(fnArgs(F.adiv_boxplot, shared, biom))"), '{"stat.by":"Sex"}')

  # The sample filter likewise.
  expect_identical(
    js$get("JSON.stringify(pruneSubset({ cat: { Sex: ['Male'], Nope: ['x'], 'Body Site': ['Moon'] }, num: { Age: [20, 30], Sex: [1, 2] } }, biom))"),
    '{"cat":{"Sex":["Male"]},"num":{"Age":[20,30]}}' )
})


test_that("a figure that waits is told its place in the queue, and a slow one what can be done", {

  js <- local_render_js()

  js$eval("const P = (status, seconds) => progress('Ordination', status, seconds);")

  # Being drawn, and not for long: as it always was.
  expect_identical(js$get("P(null, 0)"), list(heading = "Drawing: Ordination", hint = ""))
  expect_identical(js$get("P({ state: 'running' }, 3)"), list(heading = "Drawing: Ordination", hint = ""))
  expect_identical(js$get("P({ state: 'none' }, 3)")$heading, "Drawing: Ordination")

  # Waiting for a worker: the place in the queue, and that the page can be left.
  v <- js$get("P({ state: 'queued', place: 3, waiting: 5 }, 2)")
  expect_identical(v$heading, "Waiting: place 3 of 5 in the queue")
  expect_match(v$hint, "drawing other figures first")
  expect_match(v$hint, "address of this page keeps these settings")
  expect_identical(js$get("P({ state: 'queued', place: 1, waiting: 1 }, 2)")$heading, "Waiting: place 1 of 1 in the queue")

  # An answer that makes no sense says no more than that the figure is drawn.
  expect_identical(js$get("P({ state: 'queued' }, 2)")$heading, "Drawing: Ordination")
  expect_identical(js$get("P({ state: 'queued', place: 4, waiting: 2 }, 2)")$heading, "Waiting: place 4 of 4 in the queue")

  # Slow: what the user can do meanwhile. It does not promise that the
  # figure goes on being drawn while they are away.
  expect_identical(js$get("P({ state: 'running' }, SLOW_SECONDS - 1)")$hint, "")
  slow <- js$get("P({ state: 'running' }, SLOW_SECONDS)")$hint
  expect_match(slow, "bookmark")
  expect_match(slow, "drawn again")
})


test_that("the plot page keeps its settings in the address and asks where a slow figure stands", {

  src  <- read_text(www("js", "pages", "plot.js"))
  main <- read_text(www("js", "main.js"))

  # Every change of a setting goes through changed(), which writes the
  # address first. The address is replaced, not added to: the Back button
  # leaves the page, it does not undo a setting.
  expect_match(src, "function changed() {\n    keepAddress();", fixed = TRUE)
  expect_match(src, "window.history.replaceState(null, '', window.location.pathname + window.location.search + hash)", fixed = TRUE)
  expect_no_match(src, "pushState")

  # The page is handed the settings in the address, and the navigation
  # marks the page whatever settings follow its name.
  expect_match(main, "page.show(main, route.arg, route.state)", fixed = TRUE)
  expect_match(main, "const here = A.buildHash(page, arg);", fixed = TRUE)

  # The page is shown once when the app starts, so that an address with
  # another depth than the project's rarefies once (found in the browser).
  expect_match(main, "projectChanged(store.get('biom'), null);\n  if (!store.get('biom')) showPage();", fixed = TRUE)

  # The question is only asked while a figure is on its way, and stops with it.
  expect_match(src, "call('/api/plot/status')", fixed = TRUE)
  expect_match(src, "clearInterval(watch);", fixed = TRUE)
  expect_identical(match_route("POST", "/api/plot/status")$route$lane, "fast")
})
