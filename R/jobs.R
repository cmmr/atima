#______________________________________________________________________________
# Jobs and the worker pool.
#
# The main R process never calls rbiom. A handler for a `compute` route
# returns a `job()`: the name of a function in `R/worker.R`, its arguments,
# and a `finish` function. The router commits the handler's database work,
# hands the job to the pool, and answers the request with a promise. When
# the job is done, `finish` runs in the main process, in a new transaction,
# and builds the response.
#
# The pool is a set of persistent `mirai` daemons with a dispatcher. The
# main process keeps its own queue and only gives the dispatcher a job when
# a worker is free, so that a job's time limit measures running time, a
# queued job can be dropped without ever starting, and the queue has a
# length limit.
#
# The pool also keeps to a budget of CPU cores (`pool$cores`), which covers
# the web server's own process as well as the workers. A job says how many
# cores it could use (`cpus`: `Inf` if it calls an rbiom function that
# takes `cpus`, else 1) and the pool tells the worker how many it may use
# when the job starts (`pool_grant()`). What the pool counts as in use
# after that is not the grant but what it measures: every quarter of a
# second it reads how much processor time each busy worker has used
# (`pool_sample()`, with the 'ps' package). Most of rbiom runs on one core
# whatever it is given, and what does run in parallel is often over in a
# moment, so a job that was told it may use eight cores is soon counted as
# the one it is using, and the other seven are there for the next job
# (`job_cores()`).
#
# Stopping a job (because it was superseded, cancelled or ran out of time)
# first interrupts it. Compiled code may ignore an interrupt, so each job
# keeps a marker file holding its process id for as long as it runs. If the
# marker is still there after a grace period, that worker process is ended
# and a new one is started in its place.
#______________________________________________________________________________


#______________________________________________________________________________
#' Describe work for a worker process, and what to do with its result.
#'
#' @param fn      The name of a `work_*()` function.
#' @param args    Its arguments: a context, paths and validated values.
#'                Nothing that needs the database.
#' @param finish  A function of the job's result that returns the handler's
#'                response. It runs in the main process inside a database
#'                transaction, after the router has reloaded the session.
#' @param failed  A function of the error a failed job ended with (a 400
#'                from the worker, a time-out, a full queue, a crash) that
#'                returns the response to send instead. Without one the
#'                router answers as it does for any error. For callers that
#'                report errors in a form of their own (`R/mcp.R`).
#' @param cpus    The most CPU cores the work can use: 1, or `Inf` for as
#'                many as there are (see `rbiom_cpus()`). The pool tells the
#'                worker to use that many or fewer.
#' @return An object of class `job`, for a handler to return.
#' @noRd
job <- function (fn, args = list(), finish = function (result) result, failed = NULL, cpus = 1L) {
  stopifnot(is_scalar_character(fn), is.list(args), is.function(finish), is.null(failed) || is.function(failed))
  stopifnot(is.numeric(cpus), length(cpus) == 1, !is.na(cpus), cpus >= 1)
  structure(list(fn = fn, args = args, finish = finish, failed = failed, cpus = cpus), class = "job")
}


#______________________________________________________________________________
#' Describe something a handler has to wait for that needs no worker, such
#' as an answer from another server, and what to do with it.
#'
#' The router treats it as it does a `job()`: it commits the handler's
#' database work, answers the request with a promise, and when the wait is
#' over runs `finish` in the main process, in a new transaction. Any route
#' may return one, whatever its lane.
#'
#' @param start   A function with no arguments that starts the waiting and
#'                returns a promise of its result.
#' @param finish  A function of that result that returns the handler's
#'                response.
#' @return An object of class `waiting`, for a handler to return.
#' @noRd
waiting <- function (start, finish) {
  stopifnot(is.function(start), is.function(finish))
  structure(list(start = start, finish = finish, failed = NULL), class = c("waiting", "job"))
}


#______________________________________________________________________________
#' The most cores a job that calls these rbiom functions can use.
#'
#' rbiom says which of its functions run something in parallel: they take a
#' `cpus` argument. Of those, the ones worth more than one core are the
#' ones that compute distances between samples, which also take `bdiv`;
#' the others (alpha diversity, rarefying, the rarefaction plots, the Excel
#' export) were measured to take the same time on one core as on many, or
#' within a second of it. Both are read from the installed rbiom each time,
#' never from a list kept here.
#'
#' @param ...  Names of exported rbiom functions.
#' @return `Inf` if any of them takes `cpus` and `bdiv` (the job can use as
#'         many cores as there are), else `1L`.
#' @noRd
rbiom_cpus <- function (...) {
  for (fn in c(...)) {
    args <- tryCatch(names(formals(base::getExportedValue("rbiom", fn))), error = function (e) NULL)
    if (all(c("cpus", "bdiv") %in% args)) return (Inf)
  }
  1L
}


#' The most cores an export can use: those of the rbiom function that
#' computes what is exported (`work_export()`).
#' @param what  What is exported; see `api_export()`.
#' @noRd
export_cpus <- function (what) {
  if (identical(what, "beta")) rbiom_cpus("bdiv_distmat") else 1L
}


#______________________________________________________________________________
#' The context every `work_*()` function takes as its first argument.
#'
#' `cpus` is the number of cores the job may use. It is 1 here; the pool
#' puts in what it grants when the job starts (`pool_dispatch()`). A job
#' that runs without a pool has one core.
#' @noRd
worker_ctx <- function (config) {
  list(
    files_dir  = file.path(config[['data_dir']], "files"),
    cache_dir  = file.path(config[['data_dir']], "cache"),
    cache_size = config[['cache_size']],
    cpus       = 1L )
}


#______________________________________________________________________________
#' Turn what `worker_run()` returned into a value or an error.
#' @noRd
job_value <- function (outcome) {

  error <- outcome[['error']]

  if (!is.null(error))
    stop(structure(
      class = c("atima_http_error", "error", "condition"),
      list(
        message = error[['message']],
        call    = NULL,
        status  = as.integer(error[['status']]),
        detail  = error[['detail']],
        code    = error[['code']] )))

  outcome[['value']]
}


#______________________________________________________________________________
# What a worker process is asked to evaluate. Kept as quoted code because it
# runs there, with `libs`, `init`, `fn`, `args` and `marker` supplied by
# mirai. `libs` is the main process's library search path: a worker is a new
# R process and would not otherwise know of a library that was added after R
# started (by `.libPaths()`, renv and the like).
worker_load_expr <- quote({
  .libPaths(libs)
  if (is.function(init)) init()
  (get("worker_litter", envir = asNamespace("atima"), mode = "function"))()
})

worker_job_expr <- quote({
  .libPaths(libs)
  if (is.function(init)) init()
  (get("worker_run", envir = asNamespace("atima"), mode = "function"))(fn, args, marker)
})


#______________________________________________________________________________
#' Start the worker pool.
#'
#' @param workers     Number of worker processes: the most jobs that run at
#'                    the same time.
#' @param cores       The budget: CPU cores the server may use, its own
#'                    process included.
#' @param server      Cores of the budget kept for the web server's process.
#' @param most        The largest part of the free cores that one job is
#'                    given when nothing else is waiting: 1 where the
#'                    computer has one user, 0.5 on a shared server, so
#'                    that the next job to arrive finds cores free.
#' @param interval    Seconds between two readings of the workers' CPU use.
#' @param time_limit  Longest a job may run, in seconds.
#' @param grace       Seconds an interrupted job gets to stop before its
#'                    process is ended.
#' @param max_queue   Most jobs that may wait for a worker.
#' @param max_user    Most jobs one user may have waiting or running at the
#'                    same time. `Inf` for no limit.
#' @param init        A function with no arguments to call in a worker before
#'                    each job, or `NULL`. Tests use it to load the package
#'                    from source.
#' @param profile     The mirai compute profile to use.
#' @return The pool, an environment.
#' @noRd
pool_start <- function (
    workers, time_limit = 60, grace = 5, max_queue = 10L * workers,
    max_user = Inf, init = NULL, profile = "atima", timeout_note = NULL,
    cores = workers, server = 0L, most = 1, interval = 0.25 ) {

  stopifnot(workers >= 1, cores >= 1, server >= 0, cores > server, most > 0, most <= 1, interval > 0)
  stopifnot(time_limit > 0, grace >= 0, max_user >= 1)

  pool <- new.env(parent = emptyenv())

  pool$profile    <- profile
  pool$workers    <- as.integer(workers)
  pool$cores      <- as.integer(cores)
  pool$server     <- as.integer(server)
  pool$most       <- most
  pool$interval   <- interval
  pool$time_limit <- time_limit
  pool$timeout_note <- timeout_note
  pool$grace      <- grace
  pool$max_queue  <- as.integer(max_queue)
  pool$max_user   <- max_user
  pool$init       <- init
  pool$jobs       <- list()          # every queued or running job, by id
  pool$queue      <- character(0)    # ids waiting for a worker, oldest first
  pool$busy       <- 0L              # workers that may be running something
  pool$held       <- list()          # the jobs those workers have, by id
  pool$job_cores  <- 0L              # cores those jobs count for (`job_cores()`)
  pool$main_rate  <- 0               # cores the web server's process was using when last measured
  pool$used       <- 0L              # cores in use: the jobs' and the web server's
  pool$watching   <- FALSE           # is the timer that measures them running?
  pool$waiting    <- 0L              # of those workers, interrupted and not yet seen to stop
  pool$next_id    <- 0L
  # The most cores in use and jobs waiting since usage monitoring last
  # looked (`usage_sample()`), which resets them.
  pool$peak_used  <- 0L
  pool$peak_queue <- 0L
  pool$stopped    <- FALSE
  # How much processor time a process has used so far, in seconds.
  pool$cpu_time   <- process_cpu_time
  pool$main       <- list(pid = Sys.getpid())
  pool$marker_dir <- tempfile("atima_jobs_")
  pool$tempdirs   <- character(0)

  dir.create(pool$marker_dir)

  mirai::daemons(pool$workers, dispatcher = TRUE, .compute = profile)

  # Load rbiom and atima in every worker now, so that the first request does
  # not pay for it, and so that a broken installation stops the server here.
  loaded <- mirai::collect_mirai(mirai::everywhere(
    .expr    = worker_load_expr,
    .args    = list(libs = .libPaths(), init = init),
    .compute = profile ))

  failed <- Filter(mirai::is_error_value, loaded)
  if (length(failed) > 0) {
    pool_stop(pool)
    stop("The worker processes could not load atima: ", as.character(failed[[1]]), call. = FALSE)
  }

  # Each worker's temporary directory, to remove when the pool stops: a
  # worker that is ended rather than asked to quit cannot do it itself.
  pool$tempdirs <- unique(unlist(loaded))

  log_event("info", "pool_start", workers = pool$workers, cores = pool$cores, time_limit = time_limit)

  return (pool)
}


#______________________________________________________________________________
#' Stop the pool: cancel every job and end the worker processes.
#' @noRd
pool_stop <- function (pool) {

  if (isTRUE(pool$stopped)) return (invisible(NULL))
  pool$stopped <- TRUE

  stopping <- http_condition(503L, "The server is shutting down.")

  for (j in pool$jobs) {
    if (!is.null(j$mirai)) try(silent = TRUE, mirai::stop_mirai(j$mirai))
    job_settle(pool, j, error = stopping)
  }

  pool$queue <- character(0)

  try(silent = TRUE, mirai::daemons(0, .compute = pool$profile))
  unlink(pool$marker_dir, recursive = TRUE)

  # Give the workers a moment to exit, then remove what they left behind.
  Sys.sleep(0.5)
  unlink(pool$tempdirs, recursive = TRUE)

  log_event("info", "pool_stop")

  invisible(NULL)
}


#______________________________________________________________________________
#' Give a job to the pool.
#'
#' @param pool        The pool.
#' @param fn,args     The worker function's name and arguments.
#' @param session_id  The session the job belongs to, if any.
#' @param user_id     The user the job is for, if any. One user may have
#'                    `pool$max_user` jobs waiting or running; the next is
#'                    refused, so that one person's tabs, or one AI app
#'                    calling many tools at once, cannot fill the queue for
#'                    everyone. Jobs without a user are not counted.
#' @param key         Jobs with the same non-`NULL` key replace each other:
#'                    submitting one cancels any other that is queued or
#'                    running.
#' @param time_limit  Longest the job may run, in seconds.
#' @param cpus        The most CPU cores the job can use; see `job()`.
#' @return A promise. It is fulfilled with what `worker_run()` returned. It
#'         is rejected with an `atima_http_error` if the job was superseded
#'         or cancelled (409), ran out of time (504), found the queue full
#'         (503) or is one too many for its user (429), and with an ordinary
#'         error if the worker failed.
#' @noRd
pool_submit <- function (pool, fn, args, session_id = NULL, key = NULL, time_limit = pool$time_limit, user_id = NULL, cpus = 1L) {

  if (isTRUE(pool$stopped))
    return (promises::promise_reject(http_condition(503L, "The server is shutting down.")))

  if (!is.null(key))
    for (j in pool$jobs)
      if (identical(j$key, key))
        pool_cancel(pool, j, http_condition(409L, "This request was replaced by a newer one."))

  # Ids are compared as text: the database may hand out integers or doubles.
  if (!is.null(user_id)) user_id <- as.character(user_id)

  if (pool_user_jobs(pool, user_id) >= pool$max_user)
    return (promises::promise_reject(http_condition(429L, paste(
      "Too many of your requests are waiting or running at once.",
      "Please wait for some of them to finish, then try again." ))))

  if (length(pool$queue) >= pool$max_queue)
    return (promises::promise_reject(http_condition(503L, "The server is busy. Please try again in a moment.")))

  pool$next_id <- pool$next_id + 1L

  j            <- new.env(parent = emptyenv())
  j$id         <- as.character(pool$next_id)
  j$fn         <- fn
  j$args       <- args
  j$key        <- key
  j$session_id <- session_id
  j$user_id    <- user_id
  j$time_limit <- time_limit
  j$need       <- cpus
  j$cpus       <- 0L                 # cores granted; none until it starts
  j$state      <- "queued"
  j$queued_at  <- Sys.time()
  j$marker     <- file.path(pool$marker_dir, j$id)

  promise <- promises::promise(function (resolve, reject) {
    j$resolve <- resolve
    j$reject  <- reject
  })

  pool$jobs[[j$id]] <- j
  pool$queue        <- c(pool$queue, j$id)

  pool_dispatch(pool)

  pool$peak_queue <- max(pool$peak_queue, length(pool$queue))

  return (promise)
}


#______________________________________________________________________________
#' How many jobs a user has waiting or running. A running job that has been
#' told to stop (replaced or cancelled) no longer counts, although its worker
#' may need a moment to be free again.
#' @noRd
pool_user_jobs <- function (pool, user_id) {

  if (is.null(user_id)) return (0L)

  sum(vapply(pool$jobs, FUN.VALUE = logical(1), function (j) {
    identical(j$user_id, user_id) && is.null(j$reason) }))
}


#______________________________________________________________________________
#' Where the job with a key stands, for telling its owner. It only reads:
#' nothing about when a job starts depends on it.
#'
#' @param key  The key the job was submitted with; see `pool_submit()`.
#' @return `list(state)`: `"queued"`, `"running"`, or `"none"` if there is
#'         no such job (it is done, or was never there). For a queued job
#'         also `place`, its place in the queue (1 is next), and `waiting`,
#'         how many jobs are waiting in all.
#' @noRd
pool_place <- function (pool, key) {

  for (j in pool$jobs) {

    if (!identical(j$key, key) || !is.null(j$reason)) next

    if (identical(j$state, "queued"))
      return (list(state = "queued", place = match(j$id, pool$queue), waiting = length(pool$queue)))

    if (identical(j$state, "running"))
      return (list(state = "running"))
  }

  list(state = "none")
}


#______________________________________________________________________________
#' Cancel every job that belongs to a session.
#' @return The number of jobs cancelled.
#' @noRd
pool_cancel_session <- function (pool, session_id) {

  n <- 0L

  for (j in pool$jobs)
    if (identical(j$session_id, session_id)) {
      pool_cancel(pool, j, http_condition(409L, "This request was cancelled."))
      n <- n + 1L
    }

  return (n)
}


#______________________________________________________________________________
#' Cancel one job. Its promise is rejected with `reason`.
#' @noRd
pool_cancel <- function (pool, j, reason) {

  if (identical(j$state, "queued")) {
    pool$queue <- setdiff(pool$queue, j$id)
    job_settle(pool, j, error = reason)

  } else if (identical(j$state, "running")) {
    # The mirai now resolves as cancelled, which takes it to job_done().
    j$reason <- reason
    mirai::stop_mirai(j$mirai)
  }

  invisible(NULL)
}


#______________________________________________________________________________
#' How many cores the job at the head of the queue is told it may use.
#'
#' The cores that are free are shared out among that job and the jobs
#' waiting behind it. The job gets its share, but no more than it can use
#' (`need`), no more than `pool$most` of what is free, and never less than
#' one. So on a quiet server a job that can use many cores gets many, and
#' under load every new job gets one.
#'
#' @param need  The most cores the job can use.
#' @return A whole number, at least 1.
#' @noRd
pool_grant <- function (pool, need) {
  free  <- pool_free(pool)
  share <- min(free %/% (length(pool$queue) + 1L), ceiling(free * pool$most))
  as.integer(max(1, min(need, share)))
}


#' Cores of the budget that nothing is using: not the web server, which has
#' `pool$server` cores kept for it and counts for more if it is using more,
#' and not a job.
#' @noRd
pool_free <- function (pool) {
  pool$cores - max(pool$server, round(pool$main_rate)) - pool$job_cores
}


#______________________________________________________________________________
#' Start queued jobs, oldest first, while a worker and a core are free.
#' @noRd
pool_dispatch <- function (pool) {

  while (!pool$stopped && pool$busy < pool$workers && pool_free(pool) >= 1 && length(pool$queue) > 0) {

    j          <- pool$jobs[[pool$queue[[1]]]]
    pool$queue <- pool$queue[-1]
    j$cpus     <- pool_grant(pool, j$need)
    j$state    <- "running"
    j$started_at <- Sys.time()

    pool$busy  <- pool$busy + 1L
    pool$held[[j$id]] <- j
    pool_account(pool)

    # Tell the worker what it was given.
    if (is.list(j$args[['ctx']]))
      j$args[['ctx']][['cpus']] <- j$cpus

    j$mirai <- mirai::mirai(
      .expr    = worker_job_expr,
      .args    = list(libs = .libPaths(), init = pool$init, fn = j$fn, args = j$args, marker = j$marker),
      .timeout = if (is.finite(j$time_limit)) as.integer(j$time_limit * 1000),
      .compute = pool$profile )

    local({
      j <- j
      promises::then(
        promise     = j$mirai,
        onFulfilled = function (value) interruptible(job_done(pool, j)),
        onRejected  = function (error) interruptible(job_done(pool, j)) )
    })
  }

  pool_watch(pool)

  invisible(NULL)
}


#______________________________________________________________________________
#' How many cores a job that has a worker counts for.
#'
#' A job that can use several cores does so once, soon after it starts:
#' it reads its data and checks its arguments on one core, computes in
#' parallel, and does the rest on one core. So for its first `grant_hold`
#' seconds the job counts for what it was granted, or for more if it is
#' seen to use more. After that it counts for what it was measured to use
#' in the last two intervals, in whole cores, and never less than one: a
#' job that is waiting for a disk uses no processor now, but will.
#' @noRd
job_cores <- function (j) {

  if (length(j$rates) == 0) return (j$cpus)

  # Rounded up, but for the quarter of a core that a busy single thread's
  # reading may be over.
  measured <- as.integer(max(1, ceiling(max(utils::tail(j$rates, 2L)) - 0.25)))

  if (as.numeric(difftime(j$read_at, j$started_at, units = "secs")) < grant_hold)
    return (max(j$cpus, measured))

  measured
}

# Seconds for which a job counts for the cores it was told it may use,
# whatever it is seen to use.
grant_hold <- 1


#' Add up the cores in use, and note the highest total since usage
#' monitoring last looked.
#' @noRd
pool_account <- function (pool) {
  pool$job_cores <- sum(vapply(pool$held, job_cores, integer(1)))
  pool$used      <- as.integer(pool$job_cores + round(pool$main_rate))
  pool$peak_used <- max(pool$peak_used, pool$used)
  invisible(NULL)
}


#______________________________________________________________________________
#' Measure how much of the processor the web server and each busy worker
#' are using.
#'
#' The operating system keeps, for every process, the processor time all
#' its threads have used. Two readings a moment apart give the number of
#' cores the process kept busy in between: 1 for R code, more while rbiom's
#' threads (or a linear algebra library's) are running, less while it waits
#' for a disk. A job's worker is found by the process id in its marker
#' file.
#' @noRd
pool_sample <- function (pool, now = Sys.time()) {

  measure <- function (state, pid) {

    seconds <- pool$cpu_time(pid)
    if (length(seconds) != 1 || is.na(seconds)) return (state)

    if (!is.null(state$at)) {
      elapsed <- as.numeric(difftime(now, state$at, units = "secs"))
      if (elapsed <= 0) return (state)
      state$rate <- max(0, seconds - state$seconds) / elapsed
    }

    state$at      <- now
    state$seconds <- seconds
    state
  }

  pool$main <- measure(pool$main, pool$main$pid)
  pool$main_rate <- pool$main$rate %||% 0

  for (j in pool$held) {

    if (is.null(j$pid) && file.exists(j$marker))
      j$pid <- suppressWarnings(as.integer(readLines(j$marker, n = 1L, warn = FALSE)))

    if (length(j$pid) != 1 || is.na(j$pid)) next

    reading  <- measure(list(at = j$read_at, seconds = j$cpu_seconds), j$pid)
    measured <- !is.null(j$read_at) && !identical(reading$at, j$read_at)

    j$read_at     <- reading$at
    j$cpu_seconds <- reading$seconds
    if (measured) j$rates <- c(utils::tail(j$rates, 1L), reading$rate)
  }

  pool_account(pool)
}


#' The processor time a process has used so far, all its threads together.
#' @return Seconds, or `NA` if the process is gone or cannot be read.
#' @noRd
process_cpu_time <- function (pid) {
  tryCatch(
    expr  = sum(ps::ps_cpu_times(ps::ps_handle(as.integer(pid)))[c("user", "system")]),
    error = function (e) NA_real_ )
}


#' Keep measuring for as long as a worker is busy, and start waiting jobs
#' when the measurements show that cores have come free.
#' @noRd
pool_watch <- function (pool) {

  if (isTRUE(pool$watching) || isTRUE(pool$stopped) || pool$busy == 0L) return (invisible(NULL))
  pool$watching <- TRUE

  later::later(delay = pool$interval, function () interruptible({
    pool$watching <- FALSE
    if (!isTRUE(pool$stopped)) {
      pool_sample(pool)
      pool_dispatch(pool)
    }
  }))

  invisible(NULL)
}


#______________________________________________________________________________
#' A running job's mirai has resolved: with a value, an error, a timeout, a
#' cancellation, or the loss of its worker.
#' @noRd
job_done <- function (pool, j) {

  if (isTRUE(pool$stopped) || !identical(j$state, "running")) return (invisible(NULL))

  data <- j$mirai$data
  code <- if (mirai::is_error_value(data) && !mirai::is_mirai_error(data)) as.integer(data) else 0L

  if (code == 0L && !mirai::is_error_value(data)) {
    pool$tempdirs <- union(pool$tempdirs, data[['tempdir']])
    # How long the job waited for a worker and how long it ran, in
    # milliseconds, for whoever answers the request to pass on.
    data[['timing']] <- c(
      queue = as.numeric(difftime(j$started_at, j$queued_at, units = "secs")) * 1000,
      job   = as.numeric(difftime(Sys.time(), j$started_at, units = "secs")) * 1000 )
    job_settle(pool, j, value = data)
    worker_released(pool, j)

  } else if (mirai::is_mirai_error(data)) {
    # An R error in the worker that was not meant for the user.
    job_settle(pool, j, error = structure(
      class = c("atima_worker_error", "error", "condition"),
      list(
        message = paste0("Worker error in ", j$fn, "()."),
        call    = NULL,
        detail  = paste(as.character(data), collapse = " "),
        stack   = data$stack.trace )))
    worker_released(pool, j)

  } else if (code == 5L) {
    log_event("warn", "job_timeout", fn = j$fn, seconds = j$time_limit)
    job_settle(pool, j, error = http_condition(504L, paste(c(sprintf(
      "That took longer than the %i seconds allowed, and was stopped.", as.integer(j$time_limit) ),
      pool$timeout_note ), collapse = " ")))
    worker_await(pool, j)

  } else if (code == 20L) {
    job_settle(pool, j, error = j$reason %||% http_condition(409L, "This request was cancelled."))
    worker_await(pool, j)

  } else {
    # 19: the worker process died or disconnected.
    log_event("error", "worker_lost", fn = j$fn, code = code)
    job_settle(pool, j, error = structure(
      class = c("atima_worker_error", "error", "condition"),
      list(
        message = paste0("The worker process stopped unexpectedly in ", j$fn, "()."),
        call    = NULL,
        detail  = paste(as.character(data), collapse = " ") )))
    worker_gone(pool, j)
  }

  invisible(NULL)
}


#______________________________________________________________________________
#' Resolve or reject a job's promise, once, and forget the job.
#' @noRd
job_settle <- function (pool, j, value = NULL, error = NULL) {

  if (identical(j$state, "settled")) return (invisible(NULL))
  j$state <- "settled"

  pool$jobs[[j$id]] <- NULL

  if (is.null(error)) j$resolve(value) else j$reject(error)

  invisible(NULL)
}


#______________________________________________________________________________
#' The worker that ran a job is free again: stop counting the job's cores
#' and start the next queued job. Until then they count as in use, also for
#' a job that was told to stop and has not stopped yet.
#' @noRd
worker_released <- function (pool, j) {
  pool$busy <- max(0L, pool$busy - 1L)
  pool$held[[j$id]] <- NULL
  j$cpus    <- 0L
  pool_account(pool)
  pool_dispatch(pool)
}


#______________________________________________________________________________
#' Wait for an interrupted job to stop, then free its worker.
#'
#' The job has stopped when its marker file is gone and the dispatcher no
#' longer counts it as executing. (The marker alone is not enough: a job
#' interrupted in the instant before it writes its marker has none.) If the
#' marker outlives the grace period, end that worker process and start
#' another.
#' @noRd
worker_await <- function (pool, j) {

  deadline     <- Sys.time() + pool$grace
  pool$waiting <- pool$waiting + 1L

  release <- function () {
    pool$waiting <- pool$waiting - 1L
    worker_released(pool, j)
  }

  check <- function () {

    if (isTRUE(pool$stopped)) return (invisible(NULL))

    if (!file.exists(j$marker) && !pool_overcommitted(pool)) {
      release()

    } else if (Sys.time() < deadline) {
      later::later(function () interruptible(check()), 0.1)

    } else if (file.exists(j$marker)) {
      pid <- suppressWarnings(as.integer(readLines(j$marker, n = 1L, warn = FALSE)))
      log_event("warn", "worker_killed", fn = j$fn, pid = pid)
      # SIGKILL is not defined on Windows, where any signal ends the process.
      signal <- if (is.na(tools::SIGKILL)) tools::SIGTERM else tools::SIGKILL
      if (length(pid) == 1 && !is.na(pid)) tools::pskill(pid, signal)
      pool$waiting <- pool$waiting - 1L
      worker_gone(pool, j)

    } else {
      release()
    }
  }

  check()
}


#______________________________________________________________________________
#' Is the dispatcher still executing a job that this pool has given up on?
#'
#' The dispatcher's count of tasks covers the jobs the pool believes are
#' running plus any interrupted ones that have not stopped yet. If it is no
#' more than the former plus all but one of the latter, one of those the
#' pool is waiting for has certainly stopped.
#' @noRd
pool_overcommitted <- function (pool) {

  counts <- tryCatch(
    expr  = mirai::status(.compute = pool$profile)[['mirai']],
    error = function (e) NULL )

  if (is.null(counts)) return (FALSE)

  running <- sum(vapply(pool$jobs, function (j) identical(j$state, "running"), logical(1)))

  sum(counts[c("awaiting", "executing")]) > running + pool$waiting - 1L
}


#______________________________________________________________________________
#' The worker that was running a job has died or been ended. Note its
#' temporary directory for removal, start another worker, free the slot.
#' @noRd
worker_gone <- function (pool, j) {

  if (file.exists(j$marker)) {
    pool$tempdirs <- union(pool$tempdirs, readLines(j$marker, warn = FALSE)[-1])
    unlink(j$marker)
  }

  worker_replace(pool)
  worker_released(pool, j)
}


#______________________________________________________________________________
#' Start a worker process to take the place of one that is gone.
#' @noRd
worker_replace <- function (pool) {
  if (isTRUE(pool$stopped)) return (invisible(NULL))
  tryCatch(
    expr  = mirai::launch_local(1L, .compute = pool$profile),
    error = function (e) log_event("error", "worker_replace_failed", message = conditionMessage(e)) )
  invisible(NULL)
}


#______________________________________________________________________________
#' How many worker processes to start for the cores that jobs may use.
#'
#' One per core, so that every core can run a job, but no more than the
#' memory allows: each worker is an R session with rbiom loaded, which
#' holds 500 to 650 MB after it has drawn plots of a thousand samples.
#'
#' @param cores   The cores jobs may use.
#' @param memory  The memory of the computer or container in bytes, or `NA`.
#' @return A whole number, at least 1 and at most `cores`.
#' @noRd
pool_workers <- function (cores, memory = system_memory()) {
  by_memory <- if (is.na(memory)) 4 else memory %/% worker_memory
  as.integer(max(1, min(cores, by_memory)))
}

# Memory to have for each worker process, in bytes.
worker_memory <- 2 * 1024^3


#______________________________________________________________________________
#' The memory this process may count on: the computer's, or the limit of
#' the container it runs in.
#' @return Bytes, or `NA` if it cannot be found out.
#' @noRd
system_memory <- function () {

  bytes <- tryCatch(as.numeric(ps::ps_system_memory()[['total']]), error = function (e) NA_real_)

  # A container's limit (cgroup v2, then v1). "max" means there is none.
  for (file in c("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes")) {
    limit <- tryCatch(suppressWarnings(as.numeric(readLines(file, n = 1L, warn = FALSE))), error = function (e) NA_real_)
    if (length(limit) == 1 && !is.na(limit) && limit > 0) bytes <- min(bytes, limit, na.rm = TRUE)
  }

  if (length(bytes) != 1 || is.na(bytes) || bytes <= 0) NA_real_ else bytes
}


#______________________________________________________________________________
#' The time limit for a job when `run()` is not given one.
#'
#' A local install has one user and the computer is theirs, so their jobs
#' may run as long as they like. On a shared server the limit is what keeps
#' one person's long analysis from holding a worker that others wait for.
#'
#' @param auth  `"none"` or `"oidc"`.
#' @return Seconds; `Inf` for no limit.
#' @noRd
default_time_limit <- function (auth) {
  if (identical(auth, "none")) Inf else 60L
}

# Added to the message of a job that was stopped on a shared server.
timeout_note_shared <- paste(
  "Analyses have no time limit when atima runs on your own computer;",
  "see the documentation for how to install it." )


#______________________________________________________________________________
#' Run a job and wait for its result, keeping the event loop turning.
#' For work the server does for itself, such as first-run seeding, which is
#' why it has a time limit of its own instead of the one set for users.
#'
#' @param pool  The pool, or `NULL` to run the job in this process.
#' @param cpus  The most CPU cores the job can use; see `job()`.
#' @return The job's value. Stops if the job failed.
#' @noRd
pool_call <- function (pool, fn, args, time_limit = NULL, cpus = 1L) {

  if (is.null(pool))
    return (job_value(run_inline(fn, args)))

  # Ten minutes, or no limit where users have none either.
  if (is.null(time_limit))
    time_limit <- max(600, pool$time_limit)

  done    <- FALSE
  outcome <- NULL
  failure <- NULL

  promises::then(
    promise     = pool_submit(pool, fn, args, time_limit = time_limit, cpus = cpus),
    onFulfilled = function (value) { outcome <<- value; done <<- TRUE },
    onRejected  = function (error) { failure <<- error; done <<- TRUE } )

  while (!done) later::run_now(timeoutSecs = 0.1)

  if (!is.null(failure))
    stop(conditionMessage(failure), if (!is.null(failure[['detail']])) paste0(" ", failure[['detail']]), call. = FALSE)

  job_value(outcome)
}


#______________________________________________________________________________
#' Run a job in this process instead of a worker, leaving this process's
#' options as they were. Used when there is no pool, which is how most tests
#' run.
#' @return What `worker_run()` returns.
#' @noRd
run_inline <- function (fn, args) {

  prev <- options(
    rbiom.cache_dir  = NULL,
    rbiom.cache_size = NULL,
    parallelly.availableCores.custom = NULL )
  on.exit(options(prev), add = TRUE)

  worker_run(fn, args)
}
