#______________________________________________________________________________
# atima's cache of derived data.
#
# Worker processes keep what they derive from a stored BIOM file (the parsed
# object, the project summary sent to the browser) as `.rds` files in
# `<data_dir>/cache/atima`. Keys contain the SHA-256 of the files they were
# derived from, so an entry never goes stale. The main process never reads
# this cache.
#
# rbiom keeps its own cache of intermediate results (distance matrices and
# the like) in `<data_dir>/cache/rbiom`; see `worker_init()`.
#
# Writes are atomic (`atomic_write()`). A hit refreshes the entry's
# modification time, which makes that time "last used". The directory is
# only listed when a process believes the cache has outgrown its limit: each
# process keeps a running total, made of the size found at its last listing
# plus what it has written since. Other workers' writes are not in that
# total, so the cache can overshoot by a fraction of the limit per worker
# until the next listing; every `cache_resync_writes` writes force one.
#______________________________________________________________________________


# This process's view of each cache directory: bytes in use and writes since
# the directory was last listed.
cache_state <- new.env(parent = emptyenv())

cache_resync_writes <- 50L


#______________________________________________________________________________
#' Describe a cache directory.
#'
#' @param dir        The directory. It is created when first written to.
#' @param max_bytes  The size to stay under.
#' @return A list to pass to the other `cache_*()` functions.
#' @noRd
cache_at <- function (dir, max_bytes) {
  list(dir = dir, max_bytes = as.numeric(max_bytes))
}


#______________________________________________________________________________
#' The file that holds a cache entry.
#' @noRd
cache_file <- function (cache, key) {
  stopifnot(isTRUE(grepl("^[A-Za-z0-9._-]+$", key)))
  file.path(cache[['dir']], paste0(key, ".rds"))
}


#______________________________________________________________________________
#' Read a cache entry.
#' @return The cached value, or `NULL` if there is none. An unreadable entry
#'         counts as missing.
#' @noRd
cache_get <- function (cache, key) {

  file <- cache_file(cache, key)

  # Fails, quietly, when the file does not exist.
  if (!suppressWarnings(Sys.setFileTime(file, Sys.time()))) return (NULL)

  tryCatch(readRDS(file), error = function (e) NULL)
}


#______________________________________________________________________________
#' Write a cache entry, evicting the least recently used entries if the
#' cache has outgrown its limit.
#'
#' A value too large to share the cache with anything else is not stored.
#' Failing to write is never an error: the cache is only an optimisation.
#'
#' @return `value`, invisibly.
#' @noRd
cache_put <- function (cache, key, value) {

  file <- cache_file(cache, key)
  dir  <- cache[['dir']]

  tryCatch(
    error = function (e) NULL,
    expr  = suppressWarnings({

      if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)

      if (as.numeric(object.size(value)) >= cache[['max_bytes']] / 2)
        return (invisible(value))

      atomic_write(file, function (tmp) saveRDS(value, tmp))

      state <- cache_state[[dir]] %||% list(bytes = NA_real_, writes = 0L)
      state[['bytes']]  <- state[['bytes']] + file.size(file)
      state[['writes']] <- state[['writes']] + 1L
      cache_state[[dir]] <- state

      if (is.na(state[['bytes']]) || state[['bytes']] > cache[['max_bytes']] || state[['writes']] >= cache_resync_writes)
        cache_evict(cache)
    }))

  invisible(value)
}


#______________________________________________________________________________
#' Return a cached value, computing and storing it on a miss.
#' @noRd
with_cache <- function (cache, key, code) {
  value <- cache_get(cache, key)
  if (!is.null(value)) return (value)
  cache_put(cache, key, code)
}


#______________________________________________________________________________
#' List a cache directory and delete the least recently used entries until
#' it is under 80% of its limit. Also removes temporary files left behind by
#' a process that died while writing.
#'
#' @return The number of bytes in use afterwards, invisibly.
#' @noRd
cache_evict <- function (cache) {

  dir   <- cache[['dir']]
  files <- list.files(dir, full.names = TRUE)
  info  <- file.info(files, extra_cols = FALSE)
  info  <- info[!is.na(info[['size']]) & !info[['isdir']],, drop = FALSE]

  abandoned <- endsWith(rownames(info), ".tmp") & info[['mtime']] < Sys.time() - 3600
  unlink(rownames(info)[abandoned])
  info <- info[!abandoned,, drop = FALSE]

  bytes <- sum(info[['size']])

  if (bytes > cache[['max_bytes']]) {
    info   <- info[order(info[['mtime']], decreasing = TRUE),, drop = FALSE]
    remove <- cumsum(info[['size']]) > cache[['max_bytes']] * 0.8
    unlink(rownames(info)[remove])
    bytes  <- sum(info[['size']][!remove])
  }

  cache_state[[dir]] <- list(bytes = bytes, writes = 0L)

  invisible(bytes)
}
