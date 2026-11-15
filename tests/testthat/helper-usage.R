# Helpers for the tests of usage monitoring (R/usage.R, R/geo.R).


# Every row of every usage table, as one string: for checking that
# something is not in any of them.
usage_dump <- function (DB) {
  tables <- grep("^usage_", DBI::dbListTables(DB), value = TRUE)
  paste(collapse = "\n", unlist(lapply(tables, function (table) {
    rows <- DBI::dbGetQuery(DB, paste("SELECT * FROM", table))
    do.call(paste, c(lapply(rows, as.character), list(sep = "|")))
  })))
}

usage_rows <- function (DB, table = "usage_events") DBI::dbGetQuery(DB, paste("SELECT * FROM", table))

# Add an action to the record directly, for tests of the roll-ups.
add_usage_event <- function (
    DB, at, user_id, kind = "plot", outcome = "done", class = "user", interface = "ui",
    fn = NULL, queue_ms = NULL, run_ms = NULL, is_account = FALSE, app = NULL ) {
  db_insert(
    DB = DB, table = "usage_events", err_code = "TUse1",
    at_utc = at, user_id = user_id, class = class, is_account = is_account, interface = interface, app = app,
    kind = kind, fn = fn, area = if (!is.null(fn)) schema_functions[[fn]][['area']], outcome = outcome,
    queue_ms = queue_ms, run_ms = run_ms )
}


# Write a small MaxMind DB file: a search tree of 24-bit records over the
# given networks, each leading to a record in the data section.
#
#   networks  a named list: "<address>/<prefix length>" = <record>, where a
#             record is a list of strings, whole numbers and nested lists
#   version   4 or 6: the kind of tree. In a tree for IPv6, IPv4 networks
#             are placed under ::/96, as the format asks.
write_test_mmdb <- function (path, networks, version = 6L) {

  u_bytes <- function (value, n) as.raw((value %/% 256 ^ ((n - 1L):0)) %% 256)

  control <- function (type, size) {
    stopifnot(size < 65821)
    head <- if (type > 7L) c(as.raw(0L), as.raw(type - 7L)) else as.raw(type * 32L)
    add  <- function (s) { head[[1]] <- as.raw(as.integer(head[[1]]) + s); head }
    if (size < 29L)  return (add(size))
    if (size < 285L) return (c(add(29L), u_bytes(size - 29L, 1L)))
    c(add(30L), u_bytes(size - 285L, 2L))
  }

  encode <- function (x) {
    if (is.list(x)) {
      if (is.null(names(x)))
        return (c(control(11L, length(x)), unlist(lapply(x, encode))))
      return (c(control(7L, length(x)), unlist(lapply(names(x), function (key) c(encode(key), encode(x[[key]]))))))
    }
    if (is.character(x)) { bytes <- charToRaw(enc2utf8(x)); return (c(control(2L, length(bytes)), bytes)) }
    if (is.logical(x))   return (control(14L, as.integer(x)))
    n <- if (x < 65536) 2L else 4L
    c(control(if (n == 2L) 5L else 6L, n), u_bytes(x, n))
  }

  # The data section, and where each record starts in it.
  data    <- raw(0)
  offsets <- numeric(0)
  for (record in networks) {
    offsets <- c(offsets, length(data))
    data    <- c(data, encode(record))
  }

  # The tree: each node is c(left, right); NA is "nothing here", a negative
  # number is the record of that index.
  nodes <- list(c(NA_real_, NA_real_))

  for (i in seq_along(networks)) {

    parts  <- strsplit(names(networks)[[i]], "/", fixed = TRUE)[[1]]
    bits   <- ip_bits(parts[[1]])
    prefix <- as.integer(parts[[2]])

    if (version == 6L && length(bits) == 32L) { bits <- c(integer(96), bits); prefix <- prefix + 96L }

    bits <- bits[seq_len(prefix)]
    node <- 1L

    for (j in seq_along(bits)) {
      side <- bits[[j]] + 1L
      if (j == length(bits)) { nodes[[node]][[side]] <- -i; break }
      if (is.na(nodes[[node]][[side]])) {
        nodes[[length(nodes) + 1L]] <- c(NA_real_, NA_real_)
        nodes[[node]][[side]] <- length(nodes)
      }
      node <- nodes[[node]][[side]]
    }
  }

  count  <- length(nodes)
  record <- function (value) {
    if (is.na(value)) return (u_bytes(count, 3L))
    if (value < 0)    return (u_bytes(count + 16 + offsets[[-value]], 3L))
    u_bytes(value - 1L, 3L)
  }

  tree <- unlist(lapply(nodes, function (node) c(record(node[[1]]), record(node[[2]]))))

  meta <- encode(list(
    binary_format_major_version = 2L,
    binary_format_minor_version = 0L,
    database_type               = "atima-test",
    ip_version                  = as.integer(version),
    node_count                  = count,
    record_size                 = 24L ))

  writeBin(c(tree, raw(16), data, mmdb_marker, meta), path)

  invisible(path)
}
