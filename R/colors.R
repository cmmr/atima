#______________________________________________________________________________
# A colour for each group of a categorical metadata field, kept with the
# project, so that every figure colours the same group the same way.
#
# Where they are kept: in the project's stored BIOM files themselves, as one
# attribute of the HDF5 file's root, `atima-colors`, holding JSON:
# `{"<field>": {"<group>": "#RRGGBB", ...}, ...}`. rbiom and other BIOM
# readers ignore an attribute they do not know. So the colours go wherever
# the files go: into a saved project and every copy of it, through a reload
# and through rarefying, and into a downloaded HDF5 BIOM file, from which a
# new project uploaded to atima takes them again. A project that cannot be
# stored as HDF5 (`hdf5_problem()`) cannot keep colours, as it cannot keep
# an order of levels.
#
# The colours are keyed by the group's name, never by its position, so that
# putting a field's levels in another order (`work_level_order()`) leaves
# each group its colour. A field keeps its colours when it is made numeric
# and categorical again, and when the metadata is replaced; colours for
# groups a field no longer has are kept but never used.
#
# How a figure uses them is in `project_colors()` (`R/worker-plot.R`).
# Validation (`check_group_colors()`) runs in the main process; the rest
# runs in a worker.
#______________________________________________________________________________


# The name of the HDF5 attribute.
colors_attr <- "atima-colors"

# The most groups that one call may give a colour, and that one field keeps.
colors_max_n <- 1000L


#______________________________________________________________________________
#' A colour as atima stores it: `"#RRGGBB"` in capitals, or `"#RRGGBBAA"`
#' when it is not opaque. Accepted are hex codes of 3, 6 or 8 digits and
#' R's colour names (`grDevices::colors()`), in any case and with or
#' without spaces, as R reads them (`"Dark Red"` is `"darkred"`). Numbers,
#' which R would read as positions in its palette, and `"transparent"` are
#' not.
#' @param x  A character vector.
#' @return A character vector as long as `x`: `NA` where a value is not a
#'         colour.
#' @noRd
as_hex_color <- function (x) {
  vapply(x, FUN.VALUE = character(1), USE.NAMES = FALSE, function (col) {

    if (!is_scalar_character(col) || is.na(col) || nchar(col) > 40L) return (NA_character_)

    hex  <- grepl("^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", col)
    name <- tolower(gsub(" ", "", col, fixed = TRUE)) %in% colors()
    if (!hex && !name) return (NA_character_)

    rgba <- col2rgb(col, alpha = TRUE)[, 1]
    paste0(
      sprintf("#%02X%02X%02X", rgba[[1]], rgba[[2]], rgba[[3]]),
      if (rgba[[4]] < 255) sprintf("%02X", rgba[[4]]) )
  })
}


#______________________________________________________________________________
#' Check the colours a request gives the groups of a field.
#'
#' @param x  A JSON object of group name to colour: a named list of strings
#'           or a named character vector. Empty is allowed.
#' @return A named character vector of colours as `as_hex_color()` writes
#'         them, in the order given.
#' @noRd
check_group_colors <- function (x) {

  if (is.null(x) || length(x) == 0) return (stats::setNames(character(0), character(0)))

  if (is.list(x) && !is.data.frame(x)) {
    if (!all(vapply(x, function (v) is.character(v) && length(v) == 1 && !is.na(v), logical(1))))
      stop("must give each group one color, as a string")
    x <- unlist(x)
  }

  groups <- names(x)

  if (!is.character(x) || is.null(groups) || anyNA(groups))
    stop("must name the group of each color")
  if (!all(nzchar(groups)))
    stop("has a color for a group with no name, which cannot be given one")
  if (anyDuplicated(groups))
    stop("names the group '", log_truncate(groups[duplicated(groups)][[1]], 60L), "' twice")
  if (any(nchar(groups) > 500L))
    stop("has a group name longer than 500 characters")
  if (length(x) > colors_max_n)
    stop("must have at most ", colors_max_n, " colors")

  hex <- as_hex_color(unname(x))

  if (anyNA(hex)) {
    i <- which(is.na(hex))[[1]]
    stop(sprintf(
      "has '%s' for '%s', which is neither a hex code (\"#1B9E77\") nor one of R's color names (\"steelblue\")",
      log_truncate(x[[i]], 40L), log_truncate(groups[[i]], 60L) ))
  }

  stats::setNames(hex, groups)
}


#______________________________________________________________________________
#' Is a file HDF5? (Its first eight bytes are HDF5's signature.)
#' @noRd
is_hdf5_file <- function (path) {
  if (!is_scalar_character(path) || !file.exists(path)) return (FALSE)
  sig <- tryCatch(readBin(path, "raw", 8L), error = function (e) raw(0))
  identical(sig, as.raw(c(0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a)))
}


#______________________________________________________________________________
#' The group colours kept in a BIOM file.
#'
#' The file may have come from anywhere (an upload), so what is read is
#' checked as a request would be, and whatever is not a field's colours by
#' that check is left out.
#'
#' @param path  A BIOM file. A JSON or text file has none.
#' @return A named list, one entry per field, each a named character vector
#'         of colours (group name to `"#RRGGBB"`). Empty if there are none.
#' @noRd
read_colors <- function (path) {

  if (!is_hdf5_file(path)) return (list())

  json <- tryCatch(
    expr  = if (colors_attr %in% h5_attr_names(path, "/")) h5_read(path, "/", attr = colors_attr),
    error = function (e) NULL )
  if (!is_scalar_character(json) || is.na(json)) return (list())

  x <- tryCatch(fromJSON(json, simplifyVector = FALSE), error = function (e) NULL)
  if (!is.list(x) || is.null(names(x))) return (list())

  x <- x[nzchar(names(x)) & !duplicated(names(x))]
  x <- lapply(x, function (cols) tryCatch(check_group_colors(cols), error = function (e) NULL))
  Filter(length, x)
}


#______________________________________________________________________________
#' Write group colours into an HDF5 BIOM file, as `read_colors()` reads
#' them. Nothing is written into a file that is not HDF5, or when there are
#' no colours.
#' @param colors  As from `read_colors()`.
#' @return `TRUE` if they were written.
#' @noRd
write_colors <- function (path, colors) {

  colors <- Filter(length, colors)
  if (length(colors) == 0 || !is_hdf5_file(path)) return (invisible(FALSE))

  json <- as.character(toJSON(lapply(colors, function (cols) as.list(cols)), auto_unbox = TRUE))
  h5_write(I(enc2utf8(json)), path, name = "/", attr = colors_attr)

  invisible(TRUE)
}


#______________________________________________________________________________
#' The colours of a field's groups that are among its values.
#'
#' @param colors  As from `read_colors()`.
#' @param field   The field's name.
#' @param values  The field's values: a factor (its levels in use, in their
#'                order) or a character vector (its values, sorted).
#' @return A named character vector in the order of the field's levels, or
#'         `NULL` when the field is not categorical or none of its groups
#'         has a colour.
#' @noRd
field_colors <- function (colors, field, values) {

  if (!is_scalar_character(field) || is.na(field)) return (NULL)

  cols <- colors[[field]]
  if (length(cols) == 0 || is.null(values) || is.numeric(values)) return (NULL)

  levels <- if (is.factor(values)) levels(values)[levels(values) %in% values] else sort(unique(as.character(values)))
  cols   <- cols[intersect(levels, names(cols))]

  if (length(cols) == 0) NULL else cols
}
