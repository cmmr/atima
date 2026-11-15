#______________________________________________________________________________
# Country and network owner of an address, from files on this server.
#
# Usage monitoring (`R/usage.R`) records, for a visit, the country a browser
# came from and the organisation that owns its network, which is what lets
# a shared server say "used in N countries, at N institutions". Both are
# looked up here, in database files the administrator supplies
# (`run(geo_db = )`). Nothing is sent to a lookup service, and the address
# is not kept.
#
# The files are in the MaxMind DB format (`.mmdb`), which the free
# databases of DB-IP, IPinfo and MaxMind all come in. It is a binary search
# tree over the bits of an address, followed by a data section of typed
# values; `mmdb_open()` and `mmdb_find()` read it, in R, so that no other
# package is needed. The format is described at
# https://maxmind.github.io/MaxMind-DB/.
#
# The files name their fields differently, so `geo_lookup()` looks for
# either spelling: a country is `country.iso_code` (DB-IP, MaxMind) or
# `country_code` (IPinfo); a network owner is
# `autonomous_system_organization` (DB-IP, MaxMind) or `as_name` (IPinfo).
#______________________________________________________________________________


# The bytes that come before a file's metadata.
mmdb_marker <- as.raw(c(0xab, 0xcd, 0xef, utf8ToInt("MaxMind.com")))


#______________________________________________________________________________
#' Open the lookup files.
#'
#' @param paths  The `.mmdb` files, or `NULL`.
#' @return A list of open databases (`mmdb_open()`), or `NULL` for none.
#'         Stops, naming the file, if one cannot be read.
#' @noRd
geo_open <- function (paths) {

  if (length(paths) == 0) return (NULL)

  lapply(paths, function (path) tryCatch(
    expr  = mmdb_open(path),
    error = function (e) stop("geo_db: ", path, " could not be read: ", conditionMessage(e), call. = FALSE) ))
}


#______________________________________________________________________________
#' The `geo_db` setting, as file paths.
#'
#' @param value  A character vector of paths, or one string of paths
#'               separated by `;` (the form of an environment
#'               variable), or `NULL`.
#' @return The paths, or `NULL`.
#' @noRd
geo_setting <- function (value) {

  if (is.null(value)) return (NULL)

  if (!is.character(value) || anyNA(value))
    stop('geo_db must be the path of one or more .mmdb files.', call. = FALSE)

  paths <- trimws(unlist(strsplit(value, ";", fixed = TRUE)))
  paths <- paths[nzchar(paths)]

  if (length(paths) == 0) NULL else paths
}


#______________________________________________________________________________
#' Where an address is, as far as the lookup files say.
#'
#' @param geo  What `geo_open()` returned.
#' @param ip   An IPv4 or IPv6 address, as text.
#' @return `list(country, network)`: a two-letter country code and the name
#'         of the organisation that owns the network. Either may be absent;
#'         both are for an address that is not found, not an address, or
#'         when there are no files.
#' @noRd
geo_lookup <- function (geo, ip) {

  out <- list()

  for (db in geo) {

    found <- tryCatch(mmdb_find(db, ip), error = function (e) NULL)
    if (!is.list(found)) next

    country <- found[['country']]
    country <- if (is.list(country)) country[['iso_code']] else found[['country_code']]
    network <- found[['autonomous_system_organization']] %||% found[['as_name']]

    if (is.null(out[['country']]) && is_scalar_character(country) && grepl("^[A-Za-z]{2}$", country))
      out[['country']] <- toupper(country)

    if (is.null(out[['network']]) && is_scalar_character(network) && nzchar(network))
      out[['network']] <- substr(trimws(gsub("[[:cntrl:]]+", " ", network)), 1L, 120L)
  }

  out
}


#______________________________________________________________________________
#' Read a MaxMind DB file into memory.
#'
#' @return `list(bytes, node_count, record_size, ip_version, tree_size)`.
#' @noRd
mmdb_open <- function (path) {

  if (!file.exists(path)) stop("no such file")

  bytes <- readBin(path, "raw", n = file.size(path))

  # The metadata follows the last occurrence of the marker.
  first <- which(bytes == mmdb_marker[[1]])
  first <- first[first + length(mmdb_marker) - 1L <= length(bytes)]
  at    <- 0L

  for (i in rev(first))
    if (identical(bytes[i:(i + length(mmdb_marker) - 1L)], mmdb_marker)) { at <- i; break }

  if (at == 0L) stop("not a MaxMind DB file")

  meta_start <- at + length(mmdb_marker)
  meta       <- mmdb_decode(bytes, meta_start, base = meta_start)[['value']]

  node_count  <- meta[['node_count']]
  record_size <- meta[['record_size']]
  ip_version  <- meta[['ip_version']]

  if (!is.numeric(node_count) || !is.numeric(record_size) || !record_size %in% c(24, 28, 32) || !ip_version %in% c(4, 6))
    stop("its metadata cannot be used")

  list(
    bytes       = bytes,
    node_count  = node_count,
    record_size = record_size,
    ip_version  = ip_version,
    tree_size   = node_count * record_size / 4 )
}


#______________________________________________________________________________
#' The bits of an address, most significant first.
#'
#' @return An integer vector of 32 (IPv4) or 128 (IPv6) zeros and ones, or
#'         `NULL` if `ip` is not an address.
#' @noRd
ip_bits <- function (ip) {

  if (!is_scalar_character(ip) || is.na(ip)) return (NULL)

  ip <- sub("%.*$", "", trimws(ip))                  # an IPv6 zone
  ip <- sub("^\\[(.*)\\]$", "\\1", ip)

  bits_of <- function (values, width) as.integer(unlist(lapply(values, function (v) rev(as.integer(intToBits(v))[seq_len(width)]))))

  v4 <- function (text) {
    if (!grepl("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", text)) return (NULL)
    parts <- as.integer(strsplit(text, ".", fixed = TRUE)[[1]])
    if (any(parts > 255L)) NULL else parts
  }

  if (!grepl(":", ip, fixed = TRUE)) {
    parts <- v4(ip)
    return (if (is.null(parts)) NULL else bits_of(parts, 8L))
  }

  # IPv6, which may end in an IPv4 address and may have one "::".
  tail4 <- NULL
  if (grepl(".", ip, fixed = TRUE)) {
    tail4 <- v4(sub("^.*:", "", ip))
    if (is.null(tail4)) return (NULL)
    ip <- sub("[^:]*$", "0:0", ip)
  }

  if (!grepl("^[0-9A-Fa-f:]+$", ip) || length(gregexpr("::", ip, fixed = TRUE)[[1]]) > 1) return (NULL)

  groups <- function (text) if (nzchar(text)) strsplit(text, ":", fixed = TRUE)[[1]] else character(0)

  if (grepl("::", ip, fixed = TRUE)) {
    sides <- strsplit(paste0(ip, " "), "::", fixed = TRUE)[[1]]
    left  <- groups(sides[[1]])
    right <- groups(trimws(sides[[2]]))
    if (length(left) + length(right) > 7) return (NULL)
    parts <- c(left, rep("0", 8L - length(left) - length(right)), right)
  } else {
    parts <- groups(ip)
  }

  if (length(parts) != 8 || !all(grepl("^[0-9A-Fa-f]{1,4}$", parts))) return (NULL)

  values <- strtoi(parts, 16L)

  if (!is.null(tail4))
    values[7:8] <- c(tail4[[1]] * 256L + tail4[[2]], tail4[[3]] * 256L + tail4[[4]])

  bits_of(values, 16L)
}


#______________________________________________________________________________
#' Look an address up in an open MaxMind DB.
#'
#' @return The record for the address (a named list), or `NULL` if the
#'         database has none or `ip` is not an address.
#' @noRd
mmdb_find <- function (db, ip) {

  bits <- ip_bits(ip)
  if (is.null(bits)) return (NULL)

  # An IPv4 address in an IPv6 tree is under ::/96; an IPv6 address has no
  # place in an IPv4 tree, unless it is an IPv4 address written as one.
  if (db[['ip_version']] == 6 && length(bits) == 32L) bits <- c(integer(96), bits)

  if (db[['ip_version']] == 4 && length(bits) == 128L) {
    mapped <- all(bits[1:80] == 0L) && (all(bits[81:96] == 1L) || all(bits[81:96] == 0L))
    if (!mapped) return (NULL)
    bits <- bits[97:128]
  }

  bytes <- db[['bytes']]
  count <- db[['node_count']]
  size  <- db[['record_size']]
  width <- size / 4                      # bytes in one node
  node  <- 0

  for (bit in bits) {

    if (node >= count) break

    b <- as.integer(bytes[node * width + seq_len(width)])

    node <- if (size == 24) {
      if (bit == 0L) b[1] * 65536 + b[2] * 256 + b[3] else b[4] * 65536 + b[5] * 256 + b[6]
    } else if (size == 28) {
      if (bit == 0L) (b[4] %/% 16L) * 16777216 + b[1] * 65536 + b[2] * 256 + b[3]
      else           (b[4] %%  16L) * 16777216 + b[5] * 65536 + b[6] * 256 + b[7]
    } else {
      if (bit == 0L) b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4]
      else           b[5] * 16777216 + b[6] * 65536 + b[7] * 256 + b[8]
    }
  }

  # A record equal to the node count means "no data"; a larger one points
  # into the data section, which starts 16 bytes after the tree.
  if (node <= count) return (NULL)

  base   <- db[['tree_size']] + 16 + 1               # the data section's first byte, 1-based
  offset <- (node - count - 16) + base

  if (offset < base || offset > length(bytes)) return (NULL)

  mmdb_decode(bytes, offset, base = base)[['value']]
}


#______________________________________________________________________________
#' Decode the value that starts at a position of a MaxMind DB's data.
#'
#' @param bytes  The file.
#' @param at     The 1-based position of the value's first byte.
#' @param base   The 1-based position that pointers count from: the start
#'               of the data section (or of the metadata).
#' @param depth  How deep in nested values this is; a file that nests
#'               without end is refused.
#' @return `list(value, at)`: the value, and the position after it.
#' @noRd
mmdb_decode <- function (bytes, at, base, depth = 0L) {

  if (depth > 32L) stop("the data is nested too deeply")

  uint <- function (from, n) {
    if (n == 0) return (0)
    sum(as.integer(bytes[from + seq_len(n) - 1L]) * 256 ^ ((n - 1L):0))
  }

  control <- as.integer(bytes[[at]])
  type    <- control %/% 32L
  at      <- at + 1L

  # A pointer: the value is elsewhere, and decoding goes on after the pointer.
  if (type == 1L) {

    size  <- (control %/% 8L) %% 4L
    low   <- control %% 8L

    value <- switch(
      EXPR = size + 1L,
      low * 256 + uint(at, 1L),
      low * 65536 + uint(at, 2L) + 2048,
      low * 16777216 + uint(at, 3L) + 526336,
      uint(at, 4L) )

    target <- mmdb_decode(bytes, base + value, base, depth + 1L)

    return (list(value = target[['value']], at = at + size + 1L))
  }

  if (type == 0L) {
    type <- as.integer(bytes[[at]]) + 7L
    at   <- at + 1L
  }

  size <- control %% 32L

  if (size == 29L) {        size <- 29    + uint(at, 1L); at <- at + 1L
  } else if (size == 30L) { size <- 285   + uint(at, 2L); at <- at + 2L
  } else if (size == 31L) { size <- 65821 + uint(at, 3L); at <- at + 3L }

  # A map: `size` pairs of a key and a value.
  if (type == 7L) {

    value <- list()

    for (i in seq_len(size)) {
      key <- mmdb_decode(bytes, at, base, depth + 1L)
      val <- mmdb_decode(bytes, key[['at']], base, depth + 1L)
      at  <- val[['at']]
      if (is_scalar_character(key[['value']]))
        value[key[['value']]] <- list(val[['value']])
    }

    return (list(value = value, at = at))
  }

  # An array of `size` values.
  if (type == 11L) {

    value <- vector("list", size)

    for (i in seq_len(size)) {
      item       <- mmdb_decode(bytes, at, base, depth + 1L)
      value[i]   <- list(item[['value']])
      at         <- item[['at']]
    }

    return (list(value = value, at = at))
  }

  # A boolean keeps its value where the others keep their length.
  if (type == 14L) return (list(value = size != 0, at = at))

  chunk <- if (size > 0) bytes[at + seq_len(size) - 1L] else raw(0)

  value <- switch(
    EXPR = as.character(type),
    "2"  = { text <- rawToChar(chunk); Encoding(text) <- "UTF-8"; text },
    "3"  = if (size == 8) readBin(chunk, "double", size = 8L, endian = "big"),
    "15" = if (size == 4) readBin(chunk, "numeric", size = 4L, endian = "big"),
    "8"  = { v <- uint(at, size); if (size == 4 && v >= 2147483648) v - 4294967296 else v },
    "5"  = , "6" = , "9" = , "10" = uint(at, size),
    NULL )

  list(value = value, at = at + size)
}
