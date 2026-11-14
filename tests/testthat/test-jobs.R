# The worker pool: dispatch, cancellation, time limit, lost and stuck workers.
#
# Note for expressions run with `eval` in a worker: a bare `on.exit()` there
# would replace worker_run()'s own, so wrap such code in `local()`.
#
# One pool of two workers serves the whole file. Jobs here call `eval` in
# the worker (see eval_job() in helper-db.R), which stands in for a slow,
# failing or crashing `work_*()` function.


pool <- local_test_pool(workers = 2L, time_limit = 3, grace = 1, max_queue = 3L)

# A rejection may come before the test looks at the promise; the empty
# handler keeps promises from reporting it as unhandled.
quiet <- function (promise) {
  promises::catch(promise, function (error) NULL)
  promise
}

submit <- function (expr, ...) quiet(pool_submit(pool, "eval", list(expr = expr), ...))

# What a settled promise's job returned.
value_of <- function (promise, ...) {
  result <- await(promise, ...)
  if (!is.null(result$error)) stop("job failed: ", conditionMessage(result$error), " ", result$error$detail)
  job_value(result$value)
}

# The condition a promise was rejected with.
error_of <- function (promise, ...) {
  result <- await(promise, ...)
  if (is.null(result$error)) stop("job did not fail")
  result$error
}

# Wait until every worker is free and nothing is queued.
pool_idle <- function () wait_until(function () pool$busy == 0L && length(pool$jobs) == 0L)

# The process ids of the pool's workers. A worker that has only just
# connected, or is still unwinding a job that was stopped, may not answer a
# roll call (or answers with an error value), so call until both do.
worker_pids <- function () {
  pids <- integer(0)
  wait_until(seconds = 10, condition = function () {
    answers <- mirai::collect_mirai(mirai::everywhere(Sys.getpid(), .compute = pool$profile))
    answers <- Filter(function (x) !mirai::is_error_value(x), answers)
    pids   <<- sort(unlist(answers))
    length(pids) == 2L
  })
  pids
}

connections <- function () mirai::status(.compute = pool$profile)$connections

# Blocks until interrupted, as R code does; then stops.
sleep_30 <- quote(Sys.sleep(30))

# Ignores interrupts, as compiled code can. On Unix the interrupt is a
# SIGINT, which R ignores while it waits for a child process.
deaf_30 <- if (.Platform$OS.type == "windows") {
  quote(suspendInterrupts({
    until <- Sys.time() + 30
    while (Sys.time() < until) Sys.sleep(0.2)
  }))
} else {
  quote(system("sleep 30"))
}


test_that("a job runs in a worker process, not in the main process", {

  pid <- value_of(submit(quote(Sys.getpid())))

  expect_false(identical(pid, Sys.getpid()))
  expect_true(pid %in% worker_pids())
  expect_length(worker_pids(), 2L)

  # The worker has atima and rbiom loaded and waiting.
  expect_true(value_of(submit(quote(all(c("atima", "rbiom") %in% loadedNamespaces())))))

  # A real worker function, by name, with its result brought back.
  dir   <- withr::local_tempdir()
  file  <- file.path(dir, "in.txt")
  writeLines("content", file)
  entry <- value_of(pool_submit(pool, "store_file", list(files_dir = dir, file = file)))
  expect_identical(entry$hash, file_sha256(file))
  expect_true(file.exists(file.path(dir, entry$file)))

  expect_true(pool_idle())
})


test_that("two workers run two jobs at the same time, and more jobs wait their turn", {

  started <- Sys.time()
  jobs    <- lapply(1:4, function (i) submit(quote({ Sys.sleep(1); Sys.getpid() })))

  expect_identical(pool$busy, 2L)
  expect_length(pool$queue, 2L)

  pids    <- vapply(jobs, value_of, integer(1))
  elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))

  expect_length(unique(pids), 2L)
  expect_gte(elapsed, 2)
  expect_lt(elapsed, 3.9)
  expect_true(pool_idle())
})


test_that("the rbiom core limit is pinned in the worker", {

  cores <- value_of(submit(quote({
    asNamespace("atima")$worker_init(list(cache_dir = tempdir(), cache_size = 1e6, cpus = 1L))
    c(parallelly::availableCores(), getOption("rbiom.cache_size"))
  })))
  expect_identical(unname(cores), c(1, 5e5))
})


test_that("errors come back: the user's as a status, the rest as a worker error", {

  outcome <- await(submit(quote(asNamespace("atima")$stop_user("No such field."))))$value
  expect_identical(outcome$error$status, 400L)
  err <- expect_error(job_value(outcome), "No such field.", class = "atima_http_error")
  expect_identical(err$status, 400L)

  # Detail meant for the log travels with it.
  outcome <- await(submit(quote(asNamespace("atima")$with_user_errors("Unreadable.", detail = FALSE, stop("secret path")))))$value
  err     <- expect_error(job_value(outcome), "^Unreadable\\.$", class = "atima_http_error")
  expect_match(err$detail, "secret path")

  err <- error_of(submit(quote(stop("something internal"))))
  expect_s3_class(err, "atima_worker_error")
  expect_no_match(conditionMessage(err), "something internal")
  expect_match(err$detail, "something internal")

  expect_true(pool_idle())
})


test_that("a newer job with the same key cancels the running one", {

  marker <- withr::local_tempfile()

  first  <- submit(bquote(local({ on.exit(writeLines("stopped", .(marker))); writeLines("running", .(marker)); Sys.sleep(30) })), session_id = 1L, key = "1 /api/plot")
  expect_true(wait_until(function () length(list.files(pool$marker_dir)) == 1L))
  expect_true(wait_until(function () file.exists(marker)))   # it is running, not just handed over

  second <- submit(quote("second result"), session_id = 1L, key = "1 /api/plot")

  err <- error_of(first)
  expect_s3_class(err, "atima_http_error")
  expect_identical(err$status, 409L)
  expect_match(conditionMessage(err), "replaced by a newer one")

  expect_identical(value_of(second), "second result")

  # The first job really stopped: its worker is free long before 30 seconds.
  expect_true(pool_idle())
  expect_identical(readLines(marker), "stopped")
  expect_length(list.files(pool$marker_dir), 0L)

  # A different key, or none, leaves other jobs alone.
  a <- submit(quote({ Sys.sleep(0.5); "a" }), session_id = 1L, key = "1 /api/plot")
  b <- submit(quote("b"), session_id = 1L, key = "1 /api/project/rarefy")
  c <- submit(quote("c"), session_id = 1L)
  expect_identical(c(value_of(a), value_of(b), value_of(c)), c("a", "b", "c"))
})


test_that("a queued job that is superseded never starts", {

  ran <- withr::local_tempfile()

  busy   <- list(submit(sleep_30, session_id = 5L), submit(sleep_30, session_id = 5L))
  queued <- submit(bquote(writeLines("ran", .(ran))), key = "k")
  expect_length(pool$queue, 1L)

  newer <- submit(quote("newer"), key = "k")
  expect_identical(error_of(queued)$status, 409L)

  expect_identical(pool_cancel_session(pool, 5L), 2L)
  for (j in busy) expect_identical(error_of(j)$status, 409L)

  expect_identical(value_of(newer), "newer")
  expect_true(pool_idle())
  expect_false(file.exists(ran))
})


test_that("all of a session's jobs can be cancelled at once", {

  mine   <- list(submit(sleep_30, session_id = 7L), submit(sleep_30, session_id = 7L), submit(sleep_30, session_id = 7L))
  theirs <- submit(quote("theirs"), session_id = 8L)

  expect_identical(pool_cancel_session(pool, 7L), 3L)

  for (j in mine) {
    err <- error_of(j)
    expect_identical(err$status, 409L)
    expect_match(conditionMessage(err), "cancelled")
  }

  expect_identical(value_of(theirs), "theirs")
  expect_identical(pool_cancel_session(pool, 7L), 0L)
  expect_true(pool_idle())
})


test_that("a full queue turns new jobs away", {

  jobs <- lapply(1:5, function (i) submit(sleep_30, session_id = 9L))
  expect_identical(pool$busy, 2L)
  expect_length(pool$queue, 3L)

  err <- error_of(submit(quote("one too many")))
  expect_identical(err$status, 503L)

  pool_cancel_session(pool, 9L)
  for (j in jobs) expect_identical(error_of(j)$status, 409L)
  expect_true(pool_idle())
})


test_that("one user's jobs are capped, and other users are not held up by it", {

  pool$max_user <- 3
  withr::defer(pool$max_user <- Inf)

  # Two run and one waits: that is this user's three.
  mine <- lapply(1:3, function (i) submit(sleep_30, session_id = 11L, user_id = 1L))
  expect_identical(pool_user_jobs(pool, "1"), 3L)

  err <- error_of(submit(quote("one too many"), user_id = 1L))
  expect_s3_class(err, "atima_http_error")
  expect_identical(err$status, 429L)
  expect_match(conditionMessage(err), "wait for some of them to finish")

  # The same user, known by a number of another type, is still that user.
  expect_identical(error_of(submit(quote("still too many"), user_id = 1))$status, 429L)

  # Someone else still gets in the queue.
  theirs <- submit(quote("theirs"), user_id = 2L)
  expect_length(pool$queue, 2L)

  # A job that was told to stop no longer counts against its user, even
  # while its worker is still stopping.
  running <- Filter(function (j) identical(j$state, "running"), pool$jobs)
  pool_cancel(pool, running[[1]], http_condition(409L, "This request was cancelled."))
  expect_identical(pool_user_jobs(pool, "1"), 2L)

  again <- submit(quote("room again"), user_id = 1L)

  expect_identical(error_of(submit(quote("and full again"), user_id = 1L))$status, 429L)

  pool_cancel_session(pool, 11L)
  for (j in mine) expect_identical(error_of(j)$status, 409L)

  expect_identical(value_of(theirs), "theirs")
  expect_identical(value_of(again), "room again")
  expect_true(pool_idle())
  expect_identical(pool_user_jobs(pool, "1"), 0L)

  # Work that belongs to nobody is not counted.
  pool$max_user <- 1
  nobodys <- lapply(1:3, function (i) submit(quote("nobody's")))
  expect_identical(pool_user_jobs(pool, NULL), 0L)
  for (j in nobodys) expect_identical(value_of(j), "nobody's")
})


test_that("a job that runs past the time limit is stopped", {

  before  <- worker_pids()
  started <- Sys.time()

  err     <- error_of(submit(sleep_30))
  elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))

  expect_s3_class(err, "atima_http_error")
  expect_identical(err$status, 504L)
  expect_match(conditionMessage(err), "longer than the 3 seconds allowed")
  expect_gte(elapsed, 2.5)
  expect_lt(elapsed, 6)

  # An interruptible job stops by itself: the same workers carry on.
  expect_true(pool_idle())
  expect_identical(value_of(submit(quote("after timeout"))), "after timeout")
  expect_identical(worker_pids(), before)
})


test_that("the time limit counts running time, not time spent in the queue", {

  withr::defer(pool$time_limit <- 3)
  pool$time_limit <- 60

  # Both workers are busy for three seconds. A third job, allowed only two
  # seconds, waits longer than that for a worker and still succeeds, because
  # its own run is short.
  busy   <- lapply(1:2, function (i) submit(quote({ Sys.sleep(3); "done" })))
  queued <- quiet(pool_submit(pool, "eval", list(expr = quote("quick")), time_limit = 2))
  expect_length(pool$queue, 1L)

  started <- Sys.time()
  expect_identical(value_of(queued), "quick")
  expect_gte(as.numeric(difftime(Sys.time(), started, units = "secs")), 2.5)

  expect_identical(vapply(busy, value_of, ""), rep("done", 2))
  expect_true(pool_idle())
})


test_that("a job that ignores the interrupt has its worker ended and replaced", {

  log_file <- withr::local_tempfile()
  withr::local_options(atima.log = log_file)

  before <- worker_pids()

  stuck <- submit(deaf_30, key = "stuck")
  expect_true(wait_until(function () length(list.files(pool$marker_dir)) == 1L))
  stuck_pid <- as.integer(readLines(list.files(pool$marker_dir, full.names = TRUE))[[1]])

  newer <- submit(quote(Sys.getpid()), key = "stuck")
  expect_identical(error_of(stuck)$status, 409L)
  expect_false(identical(value_of(newer), stuck_pid))

  # After the grace period the stuck worker is gone and another has joined.
  expect_true(pool_idle())
  expect_true(wait_until(function () connections() == 2L))

  # (A worker that has only just connected may not answer the first roll
  # call, so ask until both do.)
  expect_true(wait_until(function () length(worker_pids()) == 2L))
  after <- worker_pids()
  expect_length(after, 2L)
  expect_false(stuck_pid %in% after)
  expect_identical(length(intersect(before, after)), 1L)

  events <- vapply(readLines(log_file), function (line) jsonlite::fromJSON(line)$event, "")
  expect_true("worker_killed" %in% events)

  # The same for a job that ignores its time limit.
  err <- error_of(submit(deaf_30))
  expect_identical(err$status, 504L)
  expect_true(pool_idle())
  expect_true(wait_until(function () connections() == 2L))

  # (A new worker has to load the package before its first job, which can
  # take longer than this pool's limit.)
  withr::defer(pool$time_limit <- 3)
  pool$time_limit <- 60
  expect_identical(value_of(submit(quote("still serving"))), "still serving")
  expect_length(worker_pids(), 2L)
})


test_that("a worker that crashes is replaced, and its job fails cleanly", {

  log_file <- withr::local_tempfile()
  withr::local_options(atima.log = log_file)

  before <- worker_pids()

  err <- error_of(submit(quote(quit(save = "no"))))
  expect_s3_class(err, "atima_worker_error")
  expect_match(conditionMessage(err), "stopped unexpectedly")

  expect_true(pool_idle())
  expect_true(wait_until(function () connections() == 2L))

  # (A worker that has only just connected may not answer the first roll
  # call, so ask until both do.)
  expect_true(wait_until(function () length(worker_pids()) == 2L))
  after <- worker_pids()
  expect_length(after, 2L)
  expect_identical(length(setdiff(after, before)), 1L)

  # Both workers, the new one included, do real work. (The new one has to
  # load the package first, which can take longer than this pool's limit.)
  withr::defer(pool$time_limit <- 3)
  pool$time_limit <- 60
  pids <- vapply(lapply(1:2, function (i) submit(quote({ Sys.sleep(0.5); loadNamespace("rbiom"); Sys.getpid() }))), value_of, 1L)
  expect_setequal(pids, after)

  events <- vapply(readLines(log_file), function (line) jsonlite::fromJSON(line)$event, "")
  expect_true("worker_lost" %in% events)
})


test_that("pool_call waits for a job, and stopping the pool ends everything", {

  expect_identical(pool_call(pool, "eval", list(expr = quote(1 + 1))), 2)

  # The server's own work is not held to the users' time limit (3 seconds
  # here), but it does have one.
  expect_identical(pool_call(pool, "eval", list(expr = quote({ Sys.sleep(4); "seeded" }))), "seeded")
  expect_error(pool_call(pool, "eval", list(expr = sleep_30), time_limit = 1), "longer than the 1 seconds allowed")
  expect_true(pool_idle())

  expect_error(pool_call(pool, "eval", list(expr = quote(stop("seed failed")))), "seed failed")
  expect_error(pool_call(pool, "eval", list(expr = quote(asNamespace("atima")$stop_user("Bad file.")))), "Bad file.", class = "atima_http_error")

  # Without a pool the job runs here, and this process's options survive.
  withr::local_options(rbiom.cache_dir = "untouched")
  expect_identical(pool_call(NULL, "eval", list(expr = quote(Sys.getpid()))), Sys.getpid())
  expect_identical(getOption("rbiom.cache_dir"), "untouched")

  # A second pool, stopped with work in hand.
  other   <- local_test_pool(workers = 1L)
  running <- quiet(pool_submit(other, "eval", list(expr = sleep_30)))
  queued  <- quiet(pool_submit(other, "eval", list(expr = sleep_30)))
  expect_true(wait_until(function () length(list.files(other$marker_dir)) == 1L))

  pool_stop(other)

  expect_identical(error_of(running)$status, 503L)
  expect_identical(error_of(queued)$status, 503L)
  expect_identical(error_of(pool_submit(other, "eval", list(expr = 1)))$status, 503L)
  expect_false(dir.exists(other$marker_dir))
  expect_false(any(dir.exists(other$tempdirs)))
  expect_identical(pool_stop(other), NULL)
})
