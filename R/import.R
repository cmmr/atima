#______________________________________________________________________________
# Reading an uploaded file, and saying what was wrong with it.
#
# Everything here runs in a worker. rbiom reads the file: a BIOM file (JSON
# or HDF5), a QIIME 2 artifact (`.qza`), a mothur `.shared` file or a table
# in delimited text. It tells them apart by their content, so the upload's
# temporary name does not matter.
#
# rbiom's errors and warnings say what is wrong with a file ("Sample column
# "A" of 'counts.tsv' looks like it has decimal commas"), and they name the
# file by its path. The path is the server's, so before a message is shown
# the path is replaced by the name the file had on the user's computer, and
# a message that still holds one of the server's directories is not shown
# at all (`import_text()`).
#______________________________________________________________________________


# What an upload can be, for the message of a file nothing could be said
# about.
upload_kinds <- paste(
  "It can be a BIOM file, a QIIME 2 feature table (.qza), a mothur .shared file,",
  "or a table of counts as tab- or comma-separated text." )


#______________________________________________________________________________
#' An uploaded file's own name, for use in a message: without directories
#' and control characters, and not too long.
#' @return The name, or `NULL` if there is nothing left of it.
#' @noRd
upload_name <- function (filename) {

  if (!is_scalar_character(filename) || is.na(filename)) return (NULL)

  name <- sub("^.*[/\\\\]", "", filename)
  name <- trimws(gsub("[[:cntrl:]]+", " ", name))

  if (!nzchar(name)) return (NULL)

  substr(name, 1, 100)
}


#______________________________________________________________________________
#' Every way a path might be written in a message: as given and in full,
#' with either kind of slash.
#' @noRd
path_spellings <- function (paths) {

  paths <- paths[!is.na(paths) & nzchar(paths)]
  full  <- suppressWarnings(normalizePath(paths, winslash = "/", mustWork = FALSE))
  both  <- unique(c(paths, full))
  both  <- unique(c(both, gsub("/", "\\", both, fixed = TRUE), gsub("\\", "/", both, fixed = TRUE)))

  both[order(nchar(both), decreasing = TRUE)]
}


#______________________________________________________________________________
#' Make one of rbiom's messages about an uploaded file fit to show.
#'
#' Removes colour codes, the line breaks and bullets that the cli package
#' adds, and advice that only makes sense at an R prompt. Puts the file's
#' own name where its path on the server was.
#'
#' @param text    The condition's message.
#' @param infile  The uploaded file on the server.
#' @param name    The name the file had on the user's computer, or `NULL`.
#' @param dirs    Directories of the server. A message that still names one
#'                of them is withheld.
#' @return One line of text for each of the message's points, joined by
#'         line breaks; or `NULL` if the message cannot be shown.
#' @noRd
import_text <- function (text, infile, name = NULL, dirs = character(0)) {

  text <- paste(text, collapse = "\n")
  text <- gsub("\033\\[[0-9;]*[A-Za-z]", "", text)
  text <- gsub("\r", "", text, fixed = TRUE)

  # The file, however it was spelled. A long path is cut to its last part
  # by rbiom, so that goes too.
  called <- if (is.null(name)) "the uploaded file" else paste0("'", name, "'")

  for (path in c(path_spellings(infile), basename(infile))) {
    text <- gsub(paste0("'", path, "'"), called, text, fixed = TRUE)
    text <- gsub(path, called, text, fixed = TRUE)
  }

  # Each point of a message starts with a bullet. cli breaks long lines,
  # so a line without a bullet carries on the one before.
  bullet <- intToUtf8(c(0x2716, 0x2139, 0x2022, 0x2714, 0x2192), multiple = TRUE)
  bullet <- paste0("(", paste(c(bullet, "!"), collapse = "|"), ")[ \t]+")
  lines  <- trimws(strsplit(text, "\n", fixed = TRUE)[[1]])
  lines  <- lines[nzchar(lines)]
  starts <- grepl(paste0("^", bullet), lines)
  if (length(lines) > 0) starts[[1]] <- TRUE
  lines  <- vapply(split(lines, cumsum(starts)), paste, character(1), collapse = " ")
  lines  <- trimws(sub(paste0("^", bullet), "", unname(lines)))

  # atima reads a tree both ways before it gives up, and an object in R's
  # memory is the project here.
  lines <- lines[!grepl("`underscores", lines, fixed = TRUE)]
  lines <- gsub("(from|in) biom object", "\\1 the project", lines)

  lines <- lines[nzchar(lines)]
  if (length(lines) == 0) return (NULL)

  ends <- grepl("[.!?:;,]$|[.!?][\"')]$", lines)
  lines[!ends] <- paste0(lines[!ends], ".")
  text <- paste(lines, collapse = "\n")

  # Anything that still points into the server is not for the user.
  where <- path_spellings(c(dirs, tempdir(), dirname(infile)))
  where <- where[nchar(where) > 3]
  for (dir in where)
    if (grepl(tolower(dir), tolower(text), fixed = TRUE))
      return (NULL)

  if (nchar(text) > 1500) text <- paste0(substr(text, 1, 1500), "...")

  text
}


#______________________________________________________________________________
#' What turns rbiom's messages about one upload into text to show.
#' @return A function of a message that returns text or `NULL`; see
#'         `import_text()`.
#' @noRd
import_cleaner <- function (ctx, infile, filename = NULL) {
  name <- upload_name(filename)
  dirs <- c(ctx[['files_dir']], ctx[['cache_dir']])
  function (text) import_text(text, infile, name, dirs)
}


#______________________________________________________________________________
#' Run code that reads an upload, keeping what rbiom has to say about it.
#'
#' @param code  The code to run.
#' @return `list(value, warnings)`, or `list(error, warnings)` when it
#'         stopped: a condition that holds the message, and the messages of
#'         the warnings raised on the way.
#' @noRd
import_try <- function (code) {

  # Whole lines, and the same bullets whatever the server's locale.
  old <- options(cli.width = 1000L, cli.unicode = TRUE, cli.num_colors = 1L)
  on.exit(options(old), add = TRUE)

  warnings <- character(0)

  value <- withCallingHandlers(
    expr    = tryCatch(code, error = function (e) {
      # rlang words a message when it is asked for, so ask now, while the
      # options above hold.
      if (inherits(e, "atima_http_error")) e else simpleError(conditionMessage(e))
    }),
    warning = function (w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    })

  if (inherits(value, "error")) return (list(error = value, warnings = warnings))

  list(value = value, warnings = warnings)
}


#______________________________________________________________________________
#' Stop because an upload could not be read, saying why if that can be
#' shown. The whole of rbiom's message goes to the server log either way.
#'
#' @param message  What could not be done, in a sentence.
#' @param error    The condition from rbiom.
#' @param clean    From `import_cleaner()`.
#' @param after    Sentences to add after rbiom's.
#' @param instead  What to say after `message` when rbiom's own words cannot
#'                 be shown.
#' @noRd
import_stop <- function (message, error, clean, after = NULL, instead = NULL) {

  if (inherits(error, "atima_http_error")) stop(error)

  original <- conditionMessage(error)
  text     <- clean(original)

  # rbiom reads some kinds of file with packages it only suggests, and
  # says how to install the one it lacks. That is for whoever runs the
  # server, who finds it in the log.
  needs <- regmatches(original, regexec("The ([A-Za-z0-9.]+) R package is required", original))[[1]]
  if (length(needs) == 2)
    text <- sprintf("This server cannot read that kind of file: the %s package is not installed.", needs[[2]])

  stop_http(
    status = 400L,
    paste(c(message, if (is.null(text)) instead else text, after), collapse = "\n"),
    detail = log_truncate(gsub("\033\\[[0-9;]*[A-Za-z]", "", original), 2000L) )
}


#______________________________________________________________________________
#' The warnings of an upload that was read, as notes for the user: what
#' rbiom left out or changed on the way in.
#' @return A character vector, at most five long.
#' @noRd
import_notes <- function (warnings, clean) {

  notes <- unlist(lapply(unique(warnings), function (w) {
    text <- clean(w)
    if (!is.null(text)) gsub("\n", " ", text, fixed = TRUE)
  }))

  notes <- as.character(notes)

  if (length(notes) > 5)
    notes <- c(notes[1:4], sprintf("And %i more notes of this kind.", length(notes) - 4L))

  vapply(notes, log_truncate, character(1), max = 600L, USE.NAMES = FALSE)
}


#______________________________________________________________________________
#' Read an uploaded file as a dataset.
#'
#' A file can carry a phylogenetic tree, and rbiom refuses the whole file
#' when the tree lacks one of the OTUs. Often the names differ only by
#' underscores, which a Newick tree may use for spaces: the file is then
#' read again with underscores kept. If the tree still does not fit, the
#' dataset is read without it and a note says so. A project with a tree
#' that does not cover its OTUs is never made.
#'
#' @param infile  The uploaded file.
#' @param clean   From `import_cleaner()`.
#' @return `list(biom, notes)`.
#' @noRd
read_upload <- function (infile, clean) {

  first <- import_try(as_rbiom(infile))

  if (is.null(first[['error']]))
    return (list(biom = first[['value']], notes = import_notes(first[['warnings']], clean)))

  # Only a complaint about the tree is worth a second reading.
  if (grepl("tree", conditionMessage(first[['error']]), ignore.case = TRUE)) {

    kept <- import_try(as_rbiom(infile, underscores = TRUE))

    if (is.null(kept[['error']]))
      return (list(biom = kept[['value']], notes = import_notes(kept[['warnings']], clean)))

    bare <- import_try(as_rbiom(infile, tree = NULL))

    if (is.null(bare[['error']])) {

      why <- clean(conditionMessage(first[['error']]))

      note <- paste(c(
        "The phylogenetic tree in this file does not match its counts, so the project was made without a tree.",
        if (!is.null(why)) gsub("\n", " ", why, fixed = TRUE),
        "UniFrac and the other metrics that need a tree are not offered until a matching tree is added to the project." ),
        collapse = " ")

      return (list(biom = bare[['value']], notes = c(note, import_notes(bare[['warnings']], clean))))
    }
  }

  import_stop(
    message = "This file could not be imported.",
    error   = first[['error']],
    clean   = clean,
    instead = upload_kinds )
}


#______________________________________________________________________________
#' Replace a dataset's metadata, taxonomy or tree with an uploaded file.
#'
#' @param biom       The dataset, an rbiom object. It is changed in place.
#' @param component  `"metadata"`, `"taxonomy"` or `"tree"`.
#' @param infile     The uploaded file.
#' @param clean      From `import_cleaner()`.
#' @return The notes: what rbiom left out or dropped.
#' @noRd
replace_component <- function (biom, component, infile, clean) {

  if (component == "tree") return (replace_tree(biom, infile, clean))

  done <- import_try(biom[[component]] <- infile)

  if (!is.null(done[['error']]))
    import_stop(
      message = sprintf("That file could not be used as the project's %s.", component),
      error   = done[['error']],
      clean   = clean,
      after   = sprintf("The %s was not changed.", component),
      instead = switch(
        EXPR     = component,
        metadata = "It should be a table (CSV or tab-separated text) with a row for each sample and the sample names in the first column.",
        taxonomy = "It should be a table with a row for each OTU and the OTU names in the first column, or a QIIME 2 taxonomy artifact (.qza)." ))

  import_notes(done[['warnings']], clean)
}


#' The tree's part of `replace_component()`. The file is read as Newick
#' says to (an underscore outside quotes is a space) and, if its tips then
#' do not cover the OTUs, with underscores kept.
#' @noRd
replace_tree <- function (biom, infile, clean) {

  refuse <- function (error, after = NULL) import_stop(
    message = "That file could not be used as the project's tree.",
    error   = error,
    clean   = clean,
    after   = c(after, "The tree was not changed."),
    instead = "It should be a tree in Newick format, or a QIIME 2 phylogeny artifact (.qza)." )

  tree <- import_try(rbiom::read_tree(infile))
  if (!is.null(tree[['error']])) refuse(tree[['error']])

  done <- import_try(biom$tree <- tree[['value']])

  if (!is.null(done[['error']])) {

    kept <- import_try(rbiom::read_tree(infile, underscores = TRUE))
    if (is.null(kept[['error']])) {
      again <- import_try(biom$tree <- kept[['value']])
      if (is.null(again[['error']])) return (import_notes(c(kept[['warnings']], again[['warnings']]), clean))
    }

    refuse(done[['error']], after = paste(
      "Use the tree that was built from this project's own OTUs, with the same names.",
      "Tips the project does not have are fine; they are left out." ))
  }

  import_notes(c(tree[['warnings']], done[['warnings']]), clean)
}
