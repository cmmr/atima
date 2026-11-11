#______________________________________________________________________________
# Text and HTML that came from a user (or from a file a user uploaded) and
# is on its way to a browser.
#
# `html_escape()` is for text: names and values that are put into HTML the
# server builds. `sanitize_html()` is for the one thing users may format,
# the project description.
#______________________________________________________________________________


#______________________________________________________________________________
#' Escape text for use in HTML, in element content or a quoted attribute.
#'
#' @param x  A character vector (or something `as.character()` accepts).
#'           Its dimensions are kept; `NA` becomes an empty string.
#' @noRd
html_escape <- function (x) {

  out <- as.character(x)
  out[is.na(out)] <- ""

  out <- gsub("&",  "&amp;",  out, fixed = TRUE)
  out <- gsub("<",  "&lt;",   out, fixed = TRUE)
  out <- gsub(">",  "&gt;",   out, fixed = TRUE)
  out <- gsub('"',  "&quot;", out, fixed = TRUE)
  out <- gsub("'",  "&#39;",  out, fixed = TRUE)

  attributes(out) <- attributes(x)[c("dim", "dimnames", "names")]
  out
}


# Elements a description may contain. None of them takes an attribute,
# except a link's `href`.
html_allowed <- c(
  "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup",
  "ul", "ol", "li", "blockquote", "code", "pre",
  "h1", "h2", "h3", "h4", "h5", "h6", "a" )

html_void <- c("br", "hr")

# Elements that are removed together with everything inside them. Any other
# element that is not allowed is removed but its text is kept.
html_dropped <- c(
  "script", "style", "iframe", "frame", "frameset", "object", "embed",
  "applet", "template", "noscript", "svg", "math", "head", "title", "meta",
  "link", "base", "form", "input", "button", "select", "option", "textarea",
  "audio", "video", "source", "track", "canvas", "img", "picture" )


#______________________________________________________________________________
#' Reduce HTML to a small set of harmless formatting elements.
#'
#' The input is parsed (by libxml2, through 'xml2') and written out again
#' from the parse tree by this function, so the result contains nothing but
#' the allowed elements, links to http(s) and mailto addresses, and escaped
#' text. Scripts, styles, event handlers, images, comments and every other
#' attribute are gone.
#'
#' @param html  A string of HTML, or `NULL` or `NA`.
#' @return A string of HTML.
#' @noRd
sanitize_html <- function (html) {

  if (is.null(html) || length(html) == 0 || anyNA(html)) return ("")

  html <- paste(as.character(html), collapse = "\n")
  if (!nzchar(trimws(html))) return ("")

  # Characters that XML cannot hold would stop the parser.
  html <- gsub("[\001-\010\013\014\016-\037]", "", enc2utf8(html), perl = TRUE)

  doc <- tryCatch(
    expr  = xml2::read_html(paste0("<div>", html, "</div>"), encoding = "UTF-8", options = c("RECOVER", "NOERROR", "NOWARNING", "NONET")),
    error = function (e) NULL )

  # Something no browser parser would make sense of either: keep the text.
  if (is.null(doc)) return (html_escape(html))

  body <- xml2::xml_find_first(doc, "//body")
  if (inherits(body, "xml_missing")) return ("")

  trimws(sanitize_nodes(xml2::xml_contents(body)))
}


#' Write out a list of parsed nodes, keeping only what is allowed.
#' @noRd
sanitize_nodes <- function (nodes) {

  out <- vapply(seq_along(nodes), FUN.VALUE = character(1), function (i) {

    node <- nodes[[i]]
    type <- xml2::xml_type(node)

    if (type %in% c("text", "cdata")) return (html_escape(xml2::xml_text(node)))
    if (type != "element")            return ("")

    tag <- tolower(xml2::xml_name(node))

    if (tag %in% html_dropped) return ("")

    inner <- sanitize_nodes(xml2::xml_contents(node))

    if (!(tag %in% html_allowed)) return (inner)
    if (tag %in% html_void)       return (paste0("<", tag, ">"))

    if (tag == "a") {
      href <- xml2::xml_attr(node, "href")
      if (!isTRUE(grepl("^(https?://|mailto:)[^[:space:][:cntrl:]]+$", href, ignore.case = TRUE)))
        return (inner)
      return (paste0('<a href="', html_escape(href), '" rel="noopener noreferrer nofollow">', inner, '</a>'))
    }

    paste0("<", tag, ">", inner, "</", tag, ">")
  })

  paste(out, collapse = "")
}
