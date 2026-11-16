#______________________________________________________________________________
# The methods text beside a result: a paragraph for the methods section of
# a manuscript, with the references it cites. Made in the worker, where the
# result is.
#
# rbiom writes it (`$methods` on any result) from what the result carries:
# the call that made it, and the history of the rbiom object it was made
# from. That history is not what atima did. atima reads a project from its
# own stored file, so rbiom would say "Data were imported from
# <sha256>.biom." (a name that means nothing to the reader, from a path on
# the server); it reads the rarefied counts from a file too, so rbiom would
# not know that samples with fewer reads were left out, or with which seed;
# and the sample filter is a change of metadata rbiom does not describe.
#
# So, before asking for the text, atima gives the result a history of what
# it did, as code that rbiom reads and never runs: the rarefaction, and a
# placeholder for the sample filter, whose sentence atima writes itself.
# The data's source is left out: the project's file and title are atima's
# business, and a manuscript describes the data in its own words. The
# sizes rbiom states (samples, OTUs, reads) are of the data the result was
# made from, after the filter. A sentence naming atima, and its reference,
# follow rbiom's sentence on the software.
#______________________________________________________________________________


# The placeholder for the sample filter in the history, and the sentence
# rbiom writes for a step it does not know (`methods_prep_step()`).
methods_filter_call     <- "biom <- atima_sample_filter(biom)"
methods_filter_sentence <- "The dataset was processed with atima_sample_filter()."

# At most this many values of a field are named in the filter's sentence.
methods_values_max <- 10L


#______________________________________________________________________________
#' The methods text for one of rbiom's results, describing what atima did.
#'
#' @param x            A plot or table from rbiom.
#' @param depth        The rarefaction depth of the counts it was made from,
#'                     or `NULL` if they were not rarefied.
#' @param subset_args  The samples kept; see `subset_biom()`.
#' @return `list(text, references)`: the paragraph, and the references as a
#'         character vector in alphabetical order. `NULL` if rbiom has no
#'         text for the result.
#' @noRd
result_methods <- function (x, depth = NULL, subset_args = list()) {

  filtered <- length(subset_args[['cat']]) + length(subset_args[['num']]) > 0

  tryCatch(
    error = function (e) NULL,
    expr  = {

      # The description of the data rbiom attached travels with the history.
      history <- attr(x, 'history', exact = TRUE)
      if (is.null(history))
        history <- tryCatch(attr(x[['data']], 'history', exact = TRUE), error = function (e) NULL)

      attr(x, 'history') <- structure(
        c(
          character(0),
          if (!is.null(depth)) sprintf("biom <- rarefy(biom, depth = %iL)", as.integer(depth)),
          if (filtered)        methods_filter_call ),
        biom_info = attr(history, 'biom_info', exact = TRUE) )

      m    <- x$methods
      text <- attr(m, 'text', exact = TRUE)
      refs <- attr(m, 'references', exact = TRUE)

      if (!is_scalar_character(text) || !nzchar(text)) return (NULL)

      if (filtered) {
        sentence <- filter_sentence(subset_args)
        text <- if (grepl(methods_filter_sentence, text, fixed = TRUE)) {
          sub(methods_filter_sentence, sentence, text, fixed = TRUE)
        } else {
          # rbiom put it in other words, or left it out.
          paste(sentence, gsub("(^|(?<=\\. ))[^.]*atima_sample_filter[^.]*\\.\\s*", "", text, perl = TRUE))
        }
      }

      text <- paste(text, sprintf(
        "The analyses were run through ATIMA %s (Smith %s), a web interface to rbiom.",
        as.character(utils::packageVersion("atima")), format(Sys.Date(), "%Y") ))

      refs <- unique(c(as.character(refs), atima_reference()))
      refs <- refs[order(tolower(refs), method = "radix")]

      list(text = text, references = refs)
    })
}


#' The methods text as a reply to the browser holds it (`toJSON()` without
#' `auto_unbox`), or `NULL` if there is none.
#' @noRd
methods_reply <- function (methods) {
  if (is.null(methods)) return (NULL)
  list(text = unbox(methods[['text']]), references = as.character(methods[['references']]))
}


#' The methods text as a tool's result holds it, or `NULL` if there is none.
#' @noRd
methods_data <- function (methods) {
  if (is.null(methods)) return (NULL)
  list(methods = list(text = methods[['text']], references = as.list(methods[['references']])))
}


#' How to cite atima: the wording of the "How to cite" page (`cite.js`).
#' @noRd
atima_reference <- function () {
  sprintf(
    "Smith DP (%s). ATIMA: Agile Toolkit for Incisive Microbial Analyses. Version %s. https://github.com/cmmr/atima",
    format(Sys.Date(), "%Y"), as.character(utils::packageVersion("atima")) )
}


#______________________________________________________________________________
#' The sentence that says which samples the filter kept.
#'
#' @param subset_args  `cat`: for each categorical field, the values kept.
#'                     `num`: for each numeric field, the lowest and highest
#'                     value kept. See `subset_biom()`.
#' @return One sentence, such as "Samples were restricted to those whose
#'         Body Site was Saliva or Stool and whose Age was from 20 to 40."
#' @noRd
filter_sentence <- function (subset_args) {

  number <- function (x) format(x, trim = TRUE, scientific = FALSE, drop0trailing = TRUE)

  clauses <- c(
    vapply(names(subset_args[['cat']]), FUN.VALUE = "", USE.NAMES = FALSE, function (field) {
      values <- as.character(subset_args[['cat']][[field]])
      n      <- length(values)
      if (field == ".sample") {
        if (n > 5) sprintf("that were among %i samples chosen by name", n)
        else       sprintf("named %s", join_words(values, "or"))
      } else {
        if (n > methods_values_max) sprintf("whose %s was one of %i chosen values", field, n)
        else                        sprintf("whose %s was %s", field, join_words(values, "or"))
      }
    }),
    vapply(names(subset_args[['num']]), FUN.VALUE = "", USE.NAMES = FALSE, function (field) {
      range <- as.numeric(subset_args[['num']][[field]])
      sprintf("whose %s was from %s to %s", field, number(range[[1]]), number(range[[2]]))
    }) )

  sprintf("Samples were restricted to those %s.", join_words(clauses, "and"))
}


#' "a", "a and b", "a, b, and c".
#' @noRd
join_words <- function (x, word) {
  n <- length(x)
  if (n <= 1) return (paste(x, collapse = ""))
  if (n == 2) return (paste(x, collapse = paste0(" ", word, " ")))
  paste0(paste(x[-n], collapse = ", "), ", ", word, " ", x[[n]])
}
