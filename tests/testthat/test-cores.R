# CPU cores: the pool's budget, what a job is told it may use, what the pool
# counts as in use (measured, not assumed), and how many workers to start.
#
# The rules are tested on a pool that has no workers, with processor times
# that the test makes up. One real pool of three workers and four cores, one
# of them the web server's, shows that the rules hold with real processes.
# A job that calls `list` in the worker returns its own arguments, the
# context among them, so it shows what the worker was told it may use.


quiet <- function (promise) {
  promises::catch(promise, function (error) NULL)
  promise
}

# A pool without workers: what pool_start() sets up, and no more.
paper_pool <- function (cores = 8L, server = 0L, most = 1) {
  p <- new.env()
  p$cores <- cores; p$server <- server; p$most <- most
  p$queue <- character(0); p$held <- list(); p$job_cores <- 0L; p$main_rate <- 0
  p$used  <- 0L; p$peak_used <- 0L; p$peak_queue <- 0L
  p$main  <- list(pid = 1L)
  p$cpu   <- c(`1` = 0)                       # processor seconds so far, by process id
  p$cpu_time <- function (pid) unname(p$cpu[as.character(pid)])
  p
}

# Give a paper pool a job that has a worker: its grant and its process.
paper_job <- function (p, id, cpus, pid, at) {
  j <- new.env()
  j$id <- id; j$cpus <- as.integer(cpus); j$pid <- pid; j$started_at <- at; j$marker <- tempfile()
  p$held[[id]] <- j
  p$cpu[as.character(pid)] <- 0
  pool_account(p)
  j
}

# Let `seconds` pass in which each process used so many cores, then measure.
pass <- function (p, at, seconds, cores) {
  for (pid in names(cores)) p$cpu[pid] <- p$cpu[pid] + cores[[pid]] * seconds
  pool_sample(p, at + seconds)
  at + seconds
}


test_that("a job is told it may use its share of the free cores, never less than one", {

  p <- paper_pool(cores = 8L)

  expect_identical(pool_free(p), 8)
  expect_identical(pool_grant(p, 1), 1L)
  expect_identical(pool_grant(p, Inf), 8L)
  expect_identical(pool_grant(p, 3), 3L)

  # One job waiting behind: half each. Three behind: two each.
  p$queue <- "a"
  expect_identical(pool_grant(p, Inf), 4L)
  p$queue <- c("a", "b", "c")
  expect_identical(pool_grant(p, Inf), 2L)
  expect_identical(pool_grant(p, 1), 1L)

  # More waiting than cores free: one core, not none.
  p$job_cores <- 6L
  expect_identical(pool_grant(p, Inf), 1L)
  p$queue <- character(0)
  expect_identical(pool_grant(p, Inf), 2L)
  p$job_cores <- 8L
  expect_identical(pool_grant(p, Inf), 1L)

  # A shared server gives one job at most half of what is free, so that the
  # next to arrive finds cores too.
  shared <- paper_pool(cores = 32L, server = 1L, most = 0.5)
  expect_identical(pool_free(shared), 31)
  expect_identical(pool_grant(shared, Inf), 16L)
  shared$job_cores <- 16L
  expect_identical(pool_grant(shared, Inf), 8L)
  shared$job_cores <- 30L
  expect_identical(pool_grant(shared, Inf), 1L)
  expect_identical(pool_grant(shared, 1), 1L)
})


test_that("the web server's process is part of the budget", {

  # One core is kept for it, whether or not it is using it.
  p <- paper_pool(cores = 4L, server = 1L)
  expect_identical(pool_free(p), 3)
  expect_identical(pool_grant(p, Inf), 3L)
  expect_identical(p$used, 0L)

  # When it is measured to use more than that, it counts for more.
  at <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  at <- pass(p, at, 0.25, c(`1` = 0))
  at <- pass(p, at, 0.25, c(`1` = 2.2))
  expect_equal(p$main_rate, 2.2)
  expect_identical(pool_free(p), 2)
  expect_identical(p$used, 2L)

  at <- pass(p, at, 0.25, c(`1` = 0.1))
  expect_identical(pool_free(p), 3)
  expect_identical(p$used, 0L)

  # Without a core of its own, on a computer with one.
  expect_identical(pool_free(paper_pool(cores = 1L)), 1)
})


test_that("a job counts for its grant for a second, then for what it is seen to use", {

  p  <- paper_pool(cores = 8L)
  t0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  j  <- paper_job(p, "1", cpus = 5, pid = 11L, at = t0)

  expect_identical(c(p$job_cores, p$used), c(5L, 5L))
  expect_identical(pool_free(p), 3)

  # It starts on one core, reading its data and checking its arguments, and
  # its parallel step takes a moment to get going. The cores it was told it
  # may use are its own meanwhile.
  at <- pass(p, t0, 0.25, c(`11` = 0))        # the first reading: nothing to compare with yet
  at <- pass(p, at, 0.25, c(`11` = 1))
  expect_identical(job_cores(j), 5L)
  at <- pass(p, at, 0.25, c(`11` = 1.5))
  expect_identical(job_cores(j), 5L)

  # The parallel step goes on past the first second: counted as measured.
  at <- pass(p, at, 0.25, c(`11` = 4.9))
  at <- pass(p, at, 0.25, c(`11` = 4.2))
  expect_identical(job_cores(j), 5L)
  at <- pass(p, at, 0.25, c(`11` = 4.2))
  expect_identical(job_cores(j), 4L)
  expect_identical(pool_free(p), 4)
  at <- pass(p, at, 0.25, c(`11` = 3.3))          # part of a core counts as a core
  at <- pass(p, at, 0.25, c(`11` = 3.3))
  expect_identical(job_cores(j), 4L)

  # Back on one core. The last two readings count, so one more passes
  # before the cores are free.
  at <- pass(p, at, 0.25, c(`11` = 1.1))
  expect_identical(job_cores(j), 4L)
  at <- pass(p, at, 0.25, c(`11` = 1.1))
  expect_identical(job_cores(j), 1L)
  expect_identical(p$job_cores, 1L)
  expect_identical(pool_free(p), 7)
  expect_identical(p$peak_used, 5L)

  # A job that is waiting for a disk still counts for a core.
  at <- pass(p, at, 0.25, c(`11` = 0))
  at <- pass(p, at, 0.25, c(`11` = 0))
  expect_identical(job_cores(j), 1L)
})


test_that("a job that never computes in parallel gives its cores up after a second", {

  p  <- paper_pool(cores = 8L)
  t0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  j  <- paper_job(p, "1", cpus = 8, pid = 11L, at = t0)

  at <- t0
  for (i in 1:3) at <- pass(p, at, 0.25, c(`11` = 1))
  expect_identical(job_cores(j), 8L)          # 0.75 seconds so far

  at <- pass(p, at, 0.25, c(`11` = 1))
  expect_identical(job_cores(j), 1L)
  expect_identical(pool_free(p), 7)

  # A one-core job is one core from the start, and stays one.
  k <- paper_job(p, "2", cpus = 1, pid = 12L, at = at)
  expect_identical(job_cores(k), 1L)
  at <- pass(p, at, 0.25, c(`11` = 1, `12` = 1))
  at <- pass(p, at, 0.25, c(`11` = 1, `12` = 1))
  expect_identical(c(p$job_cores, p$used), c(2L, 2L))
})


test_that("threads a job was not told it may use are counted all the same", {

  # A linear algebra library that starts a thread per core behind a job
  # that was granted one core.
  p  <- paper_pool(cores = 8L)
  t0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  j  <- paper_job(p, "1", cpus = 1, pid = 11L, at = t0)

  at <- pass(p, t0, 0.25, c(`11` = 0))
  at <- pass(p, at, 0.25, c(`11` = 5.6))
  expect_identical(job_cores(j), 6L)
  expect_identical(pool_free(p), 2)

  # A process that is gone, or cannot be read, changes nothing.
  p$cpu_time <- function (pid) NA_real_
  pool_sample(p, at + 0.25)
  expect_identical(job_cores(j), 6L)
})


test_that("processor time is read from the operating system", {

  before <- process_cpu_time(Sys.getpid())
  expect_true(is.numeric(before) && before > 0)

  until <- Sys.time() + 0.6
  while (Sys.time() < until) sqrt(runif(1000))

  used <- process_cpu_time(Sys.getpid()) - before
  expect_gt(used, 0.3)
  expect_lt(used, 2)

  expect_identical(process_cpu_time(-5L), NA_real_)
})


# With real workers ---------------------------------------------------------------

pool <- local_test_pool(workers = 3L, cores = 4L, server = 1L, time_limit = 5, grace = 1)

# A job that returns the cores its worker was told it may use.
told  <- function (...) quiet(pool_submit(pool, "list", list(ctx = list()), ...))
cores <- function (promise) job_value(await(promise)$value)$ctx$cpus

# A job that keeps its worker, using no processor.
sleeper <- function (seconds = 30, ...) quiet(pool_submit(pool, "eval", list(expr = bquote(Sys.sleep(.(seconds)))), ...))

# The pool's record of the job it was given last.
newest <- function () pool$jobs[[as.character(pool$next_id)]]

pool_idle <- function () wait_until(function () pool$busy == 0L && pool$job_cores == 0L && length(pool$held) == 0L && length(pool$jobs) == 0L)

status_of <- function (promise) await(promise)$error$status


test_that("a worker is told what it may use: all that is free, or one core", {

  expect_identical(c(pool$cores, pool$server, pool$workers), c(4L, 1L, 3L))

  expect_identical(cores(told()), 1L)
  expect_identical(cores(told(cpus = 2)), 2L)
  expect_identical(cores(told(cpus = Inf)), 3L)
  expect_identical(cores(told(cpus = 64)), 3L)
  expect_true(pool_idle())

  # A job that holds a core leaves two.
  held <- sleeper(session_id = 50L)
  expect_identical(pool$job_cores, 1L)
  expect_identical(cores(told(cpus = Inf)), 2L)

  pool_cancel_session(pool, 50L)
  expect_identical(status_of(held), 409L)
  expect_true(pool_idle())
})


test_that("cores a job was granted and does not use go to the jobs behind it", {

  # A job that may use every core, and uses none of them: it sleeps.
  first <- sleeper(seconds = 4, cpus = Inf)
  hog   <- newest()
  expect_identical(hog$cpus, 3L)
  expect_identical(pool$job_cores, 3L)

  # The next two wait: there is a worker for each, but no core.
  started <- Sys.time()
  a <- told(cpus = Inf)
  b <- told(cpus = Inf)
  expect_length(pool$queue, 2L)
  expect_identical(pool$busy, 1L)

  # Within a second or so the pool has measured the first job, counts it as
  # one core, and starts the others on a core each, long before it ends.
  expect_identical(c(cores(a), cores(b)), c(1L, 1L))
  expect_lt(as.numeric(difftime(Sys.time(), started, units = "secs")), 3)
  expect_identical(hog$state, "running")
  expect_identical(job_cores(hog), 1L)
  expect_lte(pool$peak_used, 4L)

  expect_null(await(first)$error)
  expect_true(pool_idle())
})


test_that("a job that could use many cores is not starved by one-core jobs, nor holds them up", {

  # Every worker is busy with a one-core job.
  busy <- lapply(1:3, function (i) sleeper(session_id = 100L + i))
  expect_identical(c(pool$busy, pool$job_cores), c(3L, 3L))

  # Behind them: a job that could use every core, then two that want one.
  big     <- sleeper(session_id = 200L, cpus = Inf)
  big_job <- newest()
  small_1 <- told()
  small_2 <- told()
  expect_identical(pool$queue, c(big_job$id, as.character(pool$next_id - 1L), as.character(pool$next_id)))

  # One core comes free. The big job is next in line and takes it: it does
  # not wait for more, and the small jobs behind it do not jump the queue.
  pool_cancel_session(pool, 101L)
  expect_true(wait_until(function () identical(big_job$state, "running")))
  expect_identical(big_job$cpus, 1L)
  expect_length(pool$queue, 2L)

  # The next core goes to the next job, while the big one is still running.
  pool_cancel_session(pool, 102L)
  expect_identical(cores(small_1), 1L)
  expect_identical(cores(small_2), 1L)
  expect_identical(big_job$state, "running")

  for (id in c(103L, 200L)) pool_cancel_session(pool, id)
  for (job in c(busy, list(big))) expect_identical(status_of(job), 409L)
  expect_true(pool_idle())
})


test_that("a job's cores stop counting however it ends", {

  log_file <- withr::local_tempfile()
  withr::local_options(atima.log = log_file)

  ends <- function (expr, ...) {
    promise <- quiet(pool_submit(pool, "eval", list(expr = expr), cpus = Inf, ...))
    expect_identical(pool$job_cores, 3L)
    result <- await(promise)
    expect_true(pool_idle())
    expect_identical(pool$used, 0L)
    result
  }

  # It finishes; it fails; it fails with a message for the user.
  expect_identical(job_value(ends(quote("done"))$value), "done")
  expect_s3_class(ends(quote(stop("broken")))$error, "atima_worker_error")
  expect_identical(ends(quote(asNamespace("atima")$stop_user("No.")))$value$error$status, 400L)

  # It runs out of time.
  expect_identical(ends(quote(Sys.sleep(30)), time_limit = 1)$error$status, 504L)

  # It is cancelled while it runs, and while it waits.
  running <- sleeper(cpus = Inf, session_id = 300L)
  queued  <- sleeper(cpus = Inf, session_id = 300L)
  expect_length(pool$queue, 1L)
  expect_identical(pool_cancel_session(pool, 300L), 2L)
  expect_identical(c(status_of(running), status_of(queued)), c(409L, 409L))
  expect_true(pool_idle())

  # Its worker dies, and another takes its place.
  expect_match(conditionMessage(ends(quote(quit(save = "no")))$error), "stopped unexpectedly")
  expect_true(wait_until(function () mirai::status(.compute = pool$profile)$connections == 3L))

  # It ignores the interrupt, so its worker is ended. It counts until then:
  # it may still be computing.
  deaf <- if (.Platform$OS.type == "windows") {
    quote(suspendInterrupts({ until <- Sys.time() + 30; while (Sys.time() < until) Sys.sleep(0.2) }))
  } else {
    quote(system("sleep 30"))
  }
  stuck <- quiet(pool_submit(pool, "eval", list(expr = deaf), session_id = 301L))
  expect_true(wait_until(function () length(list.files(pool$marker_dir)) == 1L))
  pool_cancel_session(pool, 301L)
  expect_identical(status_of(stuck), 409L)
  expect_identical(pool$job_cores, 1L)
  expect_true(pool_idle())
  expect_true(wait_until(function () mirai::status(.compute = pool$profile)$connections == 3L))

  events <- vapply(readLines(log_file), function (line) jsonlite::fromJSON(line)$event, "")
  expect_true(all(c("job_timeout", "worker_lost", "worker_killed") %in% events))

  # The timer that measures stops when there is nothing to measure.
  expect_true(wait_until(function () !pool$watching))
})


test_that("what a job can use is read from rbiom", {

  # Functions that compute distances between samples, in parallel.
  for (fn in c("bdiv_ord_plot", "bdiv_boxplot", "bdiv_corrplot", "bdiv_heatmap", "bdiv_stats", "bdiv_clusters", "bdiv_distmat"))
    expect_identical(rbiom_cpus(fn), Inf, info = fn)

  # Functions that take `cpus` and gain nothing from it, or do not take it.
  for (fn in c("adiv_boxplot", "rarefy", "rare_multiplot", "write_xlsx", "taxa_boxplot", "taxa_clusters", "no_such_function"))
    expect_identical(rbiom_cpus(fn), 1L, info = fn)
  expect_identical(rbiom_cpus(), 1L)

  # A job that calls several: any of them.
  expect_identical(rbiom_cpus("taxa_clusters", "bdiv_clusters"), Inf)
  expect_identical(rbiom_cpus("taxa_clusters", NULL), 1L)

  # For every function the app offers, it is what the function's own
  # arguments say, whatever rbiom is installed.
  for (fn in names(rbiom_schema())) {
    args <- names(formals(getExportedValue("rbiom", fn)))
    expect_identical(rbiom_cpus(fn), if (all(c("cpus", "bdiv") %in% args)) Inf else 1L, info = fn)
  }

  # An export of distances is the one export that computes any.
  expect_identical(export_cpus("beta"), Inf)
  expect_identical(export_cpus("alpha"), 1L)
  expect_identical(export_cpus("xlsx"), 1L)
  expect_identical(export_cpus("metadata"), 1L)
  expect_identical(export_cpus("original"), 1L)

  # The worker passes its grant to exactly the functions that take `cpus`.
  ctx <- list(cpus = 3L)
  expect_identical(with_cpus(ctx, function (x, cpus) cpus, list(x = 1)), 3L)
  expect_identical(with_cpus(ctx, function (x) x, list(x = 1)), 1)

  # A job says what it can use.
  expect_identical(job("work_plot", cpus = Inf)$cpus, Inf)
  expect_identical(job("work_summary")$cpus, 1L)
  expect_error(job("work_plot", cpus = 0))
})


test_that("handlers state what their jobs can use", {

  s   <- local_open_project()
  REQ <- s$REQ
  REQ$SESSION <- list(full_bf_id = 1L, rare_bf_id = 2L, server_temp = tempdir(), client_temp = "/tmp/x")

  local_mocked_bindings(biom_path = function (REQ, id) paste0("file-", id), known_summary = function (REQ) NULL)

  expect_identical(api_plot(REQ, "bdiv_ord_plot", list(bdiv = "bray"), 1183)$cpus, Inf)
  expect_identical(api_plot(REQ, "adiv_boxplot", list(), 1183)$cpus, 1L)
  expect_identical(api_plot(REQ, "taxa_stacked", list(), 1183)$cpus, 1L)
  expect_identical(api_rarefy(REQ, 1000)$cpus, 1L)
  expect_identical(api_add_clusters(REQ, "bdiv_clusters", "k")$cpus, Inf)
  expect_identical(api_add_clusters(REQ, "taxa_clusters", "k")$cpus, 1L)
  expect_identical(api_metadata_thead(REQ)$cpus, 1L)

  # Run in this process, as most tests do, a job has one core.
  expect_identical(api_plot(REQ, "bdiv_ord_plot", list(bdiv = "bray"), 1183)$args$ctx$cpus, 1L)
})


test_that("there is a worker for every core, as far as the memory goes", {

  gb <- 1024^3

  expect_identical(pool_workers(31L, 251 * gb), 31L)
  expect_identical(pool_workers(8L, 16 * gb), 8L)
  expect_identical(pool_workers(8L, 8 * gb), 4L)
  expect_identical(pool_workers(8L, 1 * gb), 1L)
  expect_identical(pool_workers(1L, 64 * gb), 1L)

  # Memory that cannot be read: the four workers atima started before.
  expect_identical(pool_workers(32L, NA_real_), 4L)
  expect_identical(pool_workers(2L, NA_real_), 2L)

  memory <- system_memory()
  expect_length(memory, 1L)
  expect_true(is.na(memory) || memory > 256 * 1024^2)
})


test_that("run() has one setting for cores", {

  expect_true("cpus" %in% names(formals(run)))
  expect_false(any(c("workers", "max_cpus") %in% names(formals(run))))
  expect_identical(deparse(formals(run)$cpus), "parallelly::availableCores()")

  # A job outside a pool, and a job the pool has not started yet, have one.
  expect_identical(worker_ctx(list(data_dir = tempdir(), cache_size = 1))$cpus, 1L)
})
