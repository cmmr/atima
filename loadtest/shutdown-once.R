# One round of "stop the worker pool while it is busy", for
# loadtest/shutdown-stress.sh, which runs this many times under a time limit
# to look for a stop that never returns (seen twice in 78 runs of the test
# suite on Linux with R 4.5; RENOVATION.md, step 6).
#
# The pool is stopped by the same calls as atima's pool_stop(), written out
# here with a line printed before and after each, so that a round that hangs
# shows in its last line which call did not come back.
#
#   Rscript shutdown-once.R <workers> <running+queued jobs> <seconds before stopping>

args    <- commandArgs(trailingOnly = TRUE)
workers <- as.integer(if (length(args) >= 1) args[[1]] else 2)
jobs    <- as.integer(if (length(args) >= 2) args[[2]] else 5)
pause   <- as.numeric(if (length(args) >= 3) args[[3]] else 1)

ns   <- asNamespace("atima")
say  <- function (...) { cat(format(Sys.time(), "%H:%M:%OS3"), ..., "\n"); flush(stdout()) }
turn <- function (seconds) { until <- Sys.time() + seconds; while (Sys.time() < until) later::run_now(0.02) }

options(atima.log = nullfile())

pool <- ns$pool_start(workers = workers, time_limit = 60)
say("pool started")

for (i in seq_len(jobs))
  promises::catch(ns$pool_submit(pool, "eval", list(expr = quote(Sys.sleep(30)))), function (e) NULL)

turn(pause)
say("running:", length(list.files(pool$marker_dir)), "queued:", length(pool$queue))

# pool_stop(), step by step.
pool$stopped <- TRUE
stopping <- ns$http_condition(503L, "The server is shutting down.")

for (j in pool$jobs) {
  if (!is.null(j$mirai)) {
    say("stop_mirai", j$id)
    try(silent = TRUE, mirai::stop_mirai(j$mirai))
  }
  ns$job_settle(pool, j, error = stopping)
}
say("jobs settled")

pool$queue <- character(0)

say("daemons(0)")
try(silent = TRUE, mirai::daemons(0, .compute = pool$profile))
say("daemons(0) returned")

unlink(pool$marker_dir, recursive = TRUE)
Sys.sleep(0.5)
unlink(pool$tempdirs, recursive = TRUE)

turn(0.2)
say("done")
