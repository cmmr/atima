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


test_that("no page of the app asks another host for anything", {

  # Addresses of other hosts may only appear as links for people to follow.
  links <- c(
    "https://www.bcm.edu/",
    "https://www.bcm.edu/research/centers/metagenomics-and-microbiome-research" )

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
