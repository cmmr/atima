# One row per load-test run, from the request files in a results directory,
# as a Markdown table.
#
#   Rscript loadtest/summarise.R loadtest/results
#
# Columns: the run; plots and table pages asked for while browsing; how many
# were answered (status 200), refused because the queue was full (503),
# stopped at the time limit (504); the response time of those answered
# (median, 95th percentile, maximum), the time they waited for a worker
# (median, 95th percentile) and the time they ran (median, 95th
# percentile); the whole page load (median, 95th percentile); and the 99th
# percentile and maximum of the probe that needs no worker.

args <- commandArgs(trailingOnly = TRUE)
dir  <- if (length(args) > 0) args[[1]] else "loadtest/results"

files <- sort(list.files(dir, pattern = "\\.requests\\.csv\\.gz$", full.names = TRUE))

q   <- function (x, p) if (length(x) == 0 || all(is.na(x))) NA_real_ else unname(stats::quantile(x, p, na.rm = TRUE))
fmt <- function (x, digits = 2) ifelse(is.na(x), "", formatC(x, format = "f", digits = digits))

rows <- lapply(files, function (file) {

  t    <- utils::read.csv(gzfile(file), stringsAsFactors = FALSE)
  run  <- sub("^[0-9TZ]+-(.*)\\.requests\\.csv\\.gz$", "\\1", basename(file))

  jobs  <- t[t$phase == "browse" & grepl("^(plot|table) ", t$kind), ]
  ok    <- jobs[jobs$status == 200, ]
  page  <- t[t$kind == "page load (whole)" & t$status == 200, ]
  probe <- t[t$phase == "browse" & t$kind == "heartbeat (probe)" & t$status == 200, ]
  flood <- t[t$kind == "flood export", ]
  sign  <- t[t$kind == "sign-in: callback", ]
  sprob <- t[t$phase == "signin" & t$kind == "heartbeat (probe)" & t$status == 200, ]
  mcp   <- t[t$kind == "mcp make_plot", ]
  mok   <- mcp[mcp$status == 200, ]

  data.frame(
    run        = run,
    jobs       = nrow(jobs),
    ok         = nrow(ok),
    `503`      = sum(jobs$status == 503),
    `504`      = sum(jobs$status == 504),
    resp_p50   = fmt(q(ok$seconds, 0.5)),
    resp_p95   = fmt(q(ok$seconds, 0.95)),
    resp_max   = fmt(q(ok$seconds, 1)),
    wait_p50   = fmt(q(ok$queue_ms, 0.5) / 1000),
    wait_p95   = fmt(q(ok$queue_ms, 0.95) / 1000),
    run_p50    = fmt(q(ok$job_ms, 0.5) / 1000),
    run_p95    = fmt(q(ok$job_ms, 0.95) / 1000),
    page_p50   = fmt(q(page$seconds, 0.5)),
    page_p95   = fmt(q(page$seconds, 0.95)),
    probe_p99  = fmt(q(probe$seconds, 0.99), 3),
    probe_max  = fmt(q(probe$seconds, 1), 3),
    flood      = if (nrow(flood) == 0) "" else paste(sprintf("%s x%d", names(table(flood$status)), as.integer(table(flood$status))), collapse = ", "),
    signin_p50 = fmt(q(sign$seconds[sign$status == 302], 0.5)),
    signin_max = fmt(q(sign$seconds[sign$status == 302], 1)),
    signin_probe_max = fmt(q(sprob$seconds, 1), 3),
    mcp        = if (nrow(mcp) == 0) "" else sprintf("%d of %d", nrow(mok), nrow(mcp)),
    mcp_p50    = fmt(q(mok$seconds, 0.5)),
    mcp_p95    = fmt(q(mok$seconds, 0.95)),
    mcp_kb     = fmt(q(mok$bytes, 0.5) / 1000, 0),
    check.names = FALSE, stringsAsFactors = FALSE )
})

table <- do.call(rbind, rows)

cat("| ", paste(names(table), collapse = " | "), " |\n", sep = "")
cat("|", paste(rep("---", ncol(table)), collapse = "|"), "|\n", sep = "")
for (i in seq_len(nrow(table)))
  cat("| ", paste(unlist(table[i, ]), collapse = " | "), " |\n", sep = "")
