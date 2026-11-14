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
#' @return An object of class `job`, for a handler to return.
#' @noRd
job <- function (fn, args = list(), finish = function (result) result, failed = NULL) {
  stopifnot(is_scalar_character(fn), is.list(args), is.function(finish), is.null(failed) || is.function(failed))
  structure(list(fn = fn, args = args, finish = finish, failed = failed), class = "job")
}


#______________________________________________________________________________
#' The context every `work_*()` function takes as its first argument.
#' @noRd
worker_ctx <- function (config) {
  list(
    files_dir  = file.path(config[['data_dir']], "files"),
    cache_dir  = file.path(config[['data_dir']], "cache"),
    cache_size = config[['cache_size']],
    cpus       = as.integer(config[['max_cpus']] %||% 1L) )
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
#' @param workers     Number of worker processes.
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
    max_user = Inf, init = NULL, profile = "atima" ) {

  stopifnot(workers >= 1, time_limit > 0, grace >= 0, max_user >= 1)

  pool <- new.env(parent = emptyenv())

  pool$profile    <- profile
  pool$workers    <- as.integer(workers)
  pool$time_limit <- time_limit
  pool$grace      <- grace
  pool$max_queue  <- as.integer(max_queue)
  pool$max_user   <- max_user
  pool$init       <- init
  pool$jobs       <- list()          # every queued or running job, by id
  pool$queue      <- character(0)    # ids waiting for a worker, oldest first
  pool$busy       <- 0L              # workers that may be running something
  pool$waiting    <- 0L              # of those, interrupted and not yet seen to stop
  pool$next_id    <- 0L
  pool$stopped    <- FALSE
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

  log_event("info", "pool_start", workers = pool$workers, time_limit = time_limit)

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
#' @return A promise. It is fulfilled with what `worker_run()` returned. It
#'         is rejected with an `atima_http_error` if the job was superseded
#'         or cancelled (409), ran out of time (504), found the queue full
#'         (503) or is one too many for its user (429), and with an ordinary
#'         error if the worker failed.
#' @noRd
pool_submit <- function (pool, fn, args, session_id = NULL, key = NULL, time_limit = pool$time_limit, user_id = NULL) {

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
  j$state      <- "queued"
  j$marker     <- file.path(pool$marker_dir, j$id)

  promise <- promises::promise(function (resolve, reject) {
    j$resolve <- resolve
    j$reject  <- reject
  })

  pool$jobs[[j$id]] <- j
  pool$queue        <- c(pool$queue, j$id)

  pool_dispatch(pool)

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
#' Start queued jobs while there are free workers.
#' @noRd
pool_dispatch <- function (pool) {

  while (!pool$stopped && pool$busy < pool$workers && length(pool$queue) > 0) {

    j          <- pool$jobs[[pool$queue[[1]]]]
    pool$queue <- pool$queue[-1]
    pool$busy  <- pool$busy + 1L
    j$state    <- "running"

    j$mirai <- mirai::mirai(
      .expr    = worker_job_expr,
      .args    = list(libs = .libPaths(), init = pool$init, fn = j$fn, args = j$args, marker = j$marker),
      .timeout = as.integer(j$time_limit * 1000),
      .compute = pool$profile )

    local({
      j <- j
      promises::then(
        promise     = j$mirai,
        onFulfilled = function (value) job_done(pool, j),
        onRejected  = function (error) job_done(pool, j) )
    })
  }

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
    job_settle(pool, j, value = data)
    worker_released(pool)

  } else if (mirai::is_mirai_error(data)) {
    # An R error in the worker that was not meant for the user.
    job_settle(pool, j, error = structure(
      class = c("atima_worker_error", "error", "condition"),
      list(
        message = paste0("Worker error in ", j$fn, "()."),
        call    = NULL,
        detail  = paste(as.character(data), collapse = " "),
        stack   = data$stack.trace )))
    worker_released(pool)

  } else if (code == 5L) {
    log_event("warn", "job_timeout", fn = j$fn, seconds = j$time_limit)
    job_settle(pool, j, error = http_condition(504L, sprintf(
      "That took longer than the %i seconds allowed, and was stopped.", as.integer(j$time_limit) )))
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
#' A worker is free again: start the next queued job.
#' @noRd
worker_released <- function (pool) {
  pool$busy <- max(0L, pool$busy - 1L)
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
    worker_released(pool)
  }

  check <- function () {

    if (isTRUE(pool$stopped)) return (invisible(NULL))

    if (!file.exists(j$marker) && !pool_overcommitted(pool)) {
      release()

    } else if (Sys.time() < deadline) {
      later::later(check, 0.1)

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
  worker_released(pool)
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
#' Run a job and wait for its result, keeping the event loop turning.
#' For work the server does for itself, such as first-run seeding, which is
#' why it has a time limit of its own instead of the one set for users.
#'
#' @param pool  The pool, or `NULL` to run the job in this process.
#' @return The job's value. Stops if the job failed.
#' @noRd
pool_call <- function (pool, fn, args, time_limit = 600) {

  if (is.null(pool))
    return (job_value(run_inline(fn, args)))

  done    <- FALSE
  outcome <- NULL
  failure <- NULL

  promises::then(
    promise     = pool_submit(pool, fn, args, time_limit = time_limit),
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
