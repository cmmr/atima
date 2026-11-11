# atima's cache of derived data.


# A cache in a new directory, with nothing known about it yet.
local_cache <- function (max_bytes, env = parent.frame()) {
  dir <- file.path(withr::local_tempdir(.local_envir = env), "cache")
  cache_at(dir, max_bytes)
}

# About `kb` kilobytes that do not compress.
blob <- function (kb) as.raw(sample(0:255, kb * 1024, replace = TRUE))


test_that("a cached value comes back, and a miss is NULL", {

  cache <- local_cache(1e6)

  expect_null(cache_get(cache, "absent"))

  cache_put(cache, "answer", list(x = 42))
  expect_identical(cache_get(cache, "answer"), list(x = 42))

  # with_cache computes once.
  n <- 0
  expect_identical(with_cache(cache, "counted", { n <- n + 1; "value" }), "value")
  expect_identical(with_cache(cache, "counted", { n <- n + 1; "value" }), "value")
  expect_identical(n, 1)

  # Keys cannot leave the cache directory.
  expect_error(cache_get(cache, "../outside"))
  expect_error(cache_put(cache, "a/b", 1))
})


test_that("cache entries are written atomically", {

  cache <- local_cache(1e6)
  seen  <- NULL

  # Watch the directory from inside the write.
  local_mocked_bindings(atomic_write = function (path, write) {
    tmp <- paste0(path, ".watching.tmp")
    write(tmp)
    seen <<- list(final_exists = file.exists(path), files = list.files(dirname(path)))
    file.rename(tmp, path)
  })

  cache_put(cache, "entry", blob(10))

  expect_false(seen$final_exists)
  expect_identical(seen$files, "entry.rds.watching.tmp")
  expect_identical(list.files(cache$dir), "entry.rds")
})


test_that("an unreadable entry counts as a miss and a failed write is not an error", {

  cache <- local_cache(1e6)

  cache_put(cache, "broken", 1:10)
  writeLines("not an rds file", cache_file(cache, "broken"))
  expect_null(cache_get(cache, "broken"))

  # A value too large to share the cache is returned but not stored.
  small <- local_cache(1000)
  expect_identical(cache_put(small, "huge", 1:10000), 1:10000)
  expect_null(cache_get(small, "huge"))

  # A directory that cannot be created.
  blocked <- withr::local_tempfile()
  writeLines("a file, not a directory", blocked)
  expect_identical(cache_put(cache_at(file.path(blocked, "sub"), 1e6), "x", 1), 1)
})


test_that("the directory is not listed again while the cache is under its limit", {

  cache <- local_cache(200 * 1024)
  lists <- 0L

  real_evict <- cache_evict
  local_mocked_bindings(cache_evict = function (cache) { lists <<- lists + 1L; real_evict(cache) })

  # The first write lists the directory once, to learn how full it is.
  cache_put(cache, "k1", blob(10))
  expect_identical(lists, 1L)

  # Misses, hits and further writes under the limit do not list it.
  for (i in 2:8) {
    expect_null(cache_get(cache, paste0("absent", i)))
    cache_put(cache, paste0("k", i), blob(10))
    expect_false(is.null(cache_get(cache, "k1")))
  }
  expect_identical(lists, 1L)

  # Going over the limit lists it once more and evicts.
  for (i in 9:25) cache_put(cache, paste0("k", i), blob(10))
  expect_gte(lists, 2L)
  expect_lte(lists, 3L)
})


test_that("eviction removes the least recently used entries", {

  cache <- local_cache(100 * 1024)
  file  <- function (key) cache_file(cache, key)
  age   <- function (key, seconds) Sys.setFileTime(file(key), Sys.time() - seconds)

  for (key in c("old", "older", "oldest", "used")) cache_put(cache, key, blob(20))

  age("old",    100)
  age("older",  200)
  age("oldest", 300)
  age("used",   400)

  # Reading an entry makes it the most recently used.
  expect_false(is.null(cache_get(cache, "used")))

  # 80 KB are in use. Two more entries take it past 100 KB.
  cache_put(cache, "new1", blob(20))
  cache_put(cache, "new2", blob(20))

  left <- sub("\\.rds$", "", list.files(cache$dir))
  expect_true(all(c("used", "new1", "new2") %in% left))
  expect_false("oldest" %in% left)
  expect_lte(sum(file.size(list.files(cache$dir, full.names = TRUE))), 100 * 1024)

  # Temporary files abandoned by a process that died are removed; one that
  # may still be being written is not.
  stale <- file.path(cache$dir, "dead.rds.123.abc.tmp")
  fresh <- file.path(cache$dir, "busy.rds.456.def.tmp")
  writeLines("x", stale); Sys.setFileTime(stale, Sys.time() - 7200)
  writeLines("x", fresh)

  cache_evict(cache)
  expect_false(file.exists(stale))
  expect_true(file.exists(fresh))
})


test_that("writes by other processes are noticed at the next resync", {

  cache <- local_cache(100 * 1024)

  cache_put(cache, "mine", blob(10))

  # Another worker fills the directory behind this process's back.
  for (i in 1:12) {
    f <- file.path(cache$dir, sprintf("theirs%02i.rds", i))
    saveRDS(blob(10), f)
    Sys.setFileTime(f, Sys.time() - 1000 + i)
  }
  expect_gt(sum(file.size(list.files(cache$dir, full.names = TRUE))), 100 * 1024)

  # Every `cache_resync_writes` writes, the directory is listed regardless.
  for (i in seq_len(cache_resync_writes)) cache_put(cache, "tiny", i)

  expect_lte(sum(file.size(list.files(cache$dir, full.names = TRUE))), 100 * 1024)
  expect_false(file.exists(file.path(cache$dir, "theirs01.rds")))
})
