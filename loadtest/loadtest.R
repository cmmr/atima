# A load test for an atima server: simulated people and AI apps, all at
# once, with every request timed.
#
#   Rscript loadtest/loadtest.R --base http://caddy --users 20 --minutes 3 \
#           --label workers-2 --out loadtest/results
#
# loadtest/README.md says how to run it against the container stack, what
# each phase does and how to read the results. Only use it on a test server:
# it makes guests, signs made-up people in and fills the queue on purpose.
#
# Needs the packages curl and jsonlite, and nothing from atima. One R
# process drives every simulated client through libcurl's multi interface,
# so the test machine needs little; times are those libcurl measures.
#
# Options (all `--name value`):
#   base      address of the server                    http://127.0.0.1:8080
#   mode      "shared" (accounts) or "local" (none)    shared
#   users     simulated people browsing                10
#   minutes   how long they browse                     2
#   think     mean seconds between a person's actions  5
#   flood     requests one person starts at once       40   (0 to skip)
#   agents    AI apps calling tools (local mode)       1
#   calls     make_plot calls an app makes at once     6
#   rounds    how many times each app does that        5
#   signins   people signing in at once (shared mode)  10   (0 to skip)
#   issuer    address of the mock sign-in provider, as this script reaches
#             it (loadtest/mock-issuer.R)              (none: skip sign-in)
#   label     a name for this run                      run
#   out       directory for the result files           loadtest/results
#   note      free text stored with the results (hardware, settings)
#   seed      random seed                              1

suppressPackageStartupMessages({ library(curl); library(jsonlite) })

`%||%` <- function (x, y) if (is.null(x)) y else x


# Options ----------------------------------------------------------------------

options_from <- function (args, defaults) {
  opts <- defaults
  i <- 1L
  while (i <= length(args)) {
    name <- sub("^--", "", args[[i]])
    if (!startsWith(args[[i]], "--") || !name %in% names(defaults) || i == length(args))
      stop("Unknown or incomplete option: ", args[[i]], call. = FALSE)
    opts[[name]] <- args[[i + 1L]]
    i <- i + 2L
  }
  opts
}

opt <- options_from(commandArgs(trailingOnly = TRUE), list(
  base = "http://127.0.0.1:8080", mode = "shared", users = "10", minutes = "2",
  think = "5", flood = "40", agents = "1", calls = "6", rounds = "5",
  signins = "10", issuer = "", label = "run", out = "loadtest/results",
  note = "", seed = "1" ))

for (name in c("users", "flood", "agents", "calls", "rounds", "signins", "seed"))
  opt[[name]] <- as.integer(opt[[name]])
for (name in c("minutes", "think"))
  opt[[name]] <- as.numeric(opt[[name]])

opt$base   <- sub("/+$", "", opt$base)
opt$issuer <- sub("/+$", "", opt$issuer)
stopifnot(opt$mode %in% c("shared", "local"))

set.seed(opt$seed)


# Requests and the clock -------------------------------------------------------

pool    <- curl::new_pool(total_con = 2000, host_con = 2000)
records <- new.env()
records$rows <- list()
timers  <- list()
phase   <- "setup"
started <- Sys.time()

now <- function () as.numeric(difftime(Sys.time(), started, units = "secs"))

# Call `fn` in `seconds` from now.
after <- function (seconds, fn) {
  timers[[length(timers) + 1L]] <<- list(at = now() + seconds, fn = fn)
  invisible(NULL)
}

header_value <- function (headers, name) {
  lines <- strsplit(rawToChar(headers), "\r\n", fixed = TRUE)[[1]]
  hits  <- lines[startsWith(tolower(lines), paste0(tolower(name), ":"))]
  trimws(sub("^[^:]*:", "", hits))
}

# The server says how long a job waited for a worker and how long it ran:
#   Server-Timing: queue;dur=12.3, job;dur=456.7
server_timing <- function (headers, what) {
  value <- header_value(headers, "server-timing")
  if (length(value) == 0) return (NA_real_)
  found <- regmatches(value[[1]], regexpr(paste0(what, ";dur=[0-9.]+"), value[[1]]))
  if (length(found) == 0) NA_real_ else as.numeric(sub("^.*=", "", found))
}

# Send one request. `done(status, body, headers)` is called when it ends;
# status 0 means no answer at all.
send <- function (kind, method, url, body = NULL, headers = character(0), done = function (...) NULL, who = NA) {

  handle <- curl::new_handle()
  curl::handle_setopt(
    handle, customrequest = method, followlocation = FALSE, ssl_verifypeer = FALSE,
    ssl_verifyhost = FALSE, timeout = 600, useragent = "atima-loadtest" )

  if (!is.null(body)) {
    if (is.list(body)) {
      body    <- as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null", digits = NA))
      headers <- c(headers, "Content-Type" = "application/json")
    }
    curl::handle_setopt(handle, postfields = body, postfieldsize = nchar(body, "bytes"))
  }

  if (length(headers) > 0)
    curl::handle_setheaders(handle, .list = as.list(headers))

  sent     <- now()
  at_phase <- phase

  note <- function (status, seconds, bytes, queue = NA_real_, job = NA_real_) {
    records$rows[[length(records$rows) + 1L]] <- list(
      phase = at_phase, kind = kind, who = who, sent = round(sent, 3), status = status,
      seconds = round(seconds, 4), queue_ms = queue, job_ms = job, bytes = bytes )
  }

  curl::multi_add(
    handle = handle, pool = pool,
    done   = function (res) {
      note(res$status_code, unname(res$times[["total"]]), length(res$content),
           server_timing(res$headers, "queue"), server_timing(res$headers, "job"))
      done(res$status_code, res$content, res$headers)
    },
    fail   = function (message) {
      note(0L, now() - sent, 0L)
      done(0L, raw(0), raw(0))
    })

  invisible(NULL)
}

# Keep requests and timers going until `finished()` says so.
run_until <- function (finished) {
  repeat {
    curl::multi_run(timeout = 0.02, poll = TRUE, pool = pool)
    due <- vapply(timers, function (t) t$at <= now(), logical(1))
    if (any(due)) {
      ready    <- timers[due]
      timers <<- timers[!due]
      for (t in ready) t$fn()
    }
    if (finished()) break
  }
}

json_of <- function (content) {
  tryCatch(jsonlite::fromJSON(rawToChar(content), simplifyVector = FALSE), error = function (e) NULL)
}


# What a person looking at a project asks for ----------------------------------

# Arguments that exist in each example project. Permutation tests get a new
# seed every time, so they are always computed (999 permutations, rbiom's
# default) and never come from the cache; the other plots repeat, as real
# ones do, and the cache may answer them.
projects <- list(
  hmp50 = list(group = "Body Site", pair = "Sex",      number = "Age", rank = c("Phylum", "Family", "Genus")),
  gems  = list(group = "country",   pair = "diarrhea", number = "age", rank = c("Phylum", "Family", "Genus")) )

any_seed <- function () sample.int(1e6, 1)

plot_request <- function (project) {

  p <- projects[[project]]

  choice <- sample(
    x    = c("adiv_boxplot", "adiv_corrplot", "bdiv_ord_plot", "bdiv_boxplot", "taxa_stacked", "taxa_heatmap", "taxa_boxplot", "taxa_forest", "rare_corrplot"),
    size = 1,
    prob = c(0.22, 0.08, 0.18, 0.08, 0.12, 0.10, 0.10, 0.07, 0.05) )

  args <- switch(
    EXPR = choice,
    adiv_boxplot  = list(x = p$group, stat.by = p$group, adiv = sample(c("shannon", "simpson", "observed", "chao1"), 1)),
    adiv_corrplot = list(x = p$number, stat.by = p$pair),
    bdiv_ord_plot = list(bdiv = sample(c("bray", "jaccard"), 1), stat.by = p$group, seed = any_seed()),
    bdiv_boxplot  = list(x = p$pair, bdiv = "bray", stat.by = p$pair, seed = any_seed()),
    taxa_stacked  = list(rank = sample(p$rank, 1)),
    taxa_heatmap  = list(rank = sample(p$rank, 1), taxa = sample(c(10, 20), 1), tracks = p$group),
    taxa_boxplot  = list(x = p$group, stat.by = p$group, rank = sample(p$rank, 1), taxa = 6),
    taxa_forest   = list(stat.by = p$pair, rank = sample(p$rank, 1)),
    rare_corrplot = list(stat.by = p$group) )

  list(kind = paste0("plot ", choice), fn = choice, args = args)
}


# A person in a browser ---------------------------------------------------------

static_files <- character(0)

# The files a page load fetches: index.html names the style sheet and the
# first script, and each script names the scripts it imports.
discover_static <- function () {

  get <- function (path) {
    res <- curl::curl_fetch_memory(paste0(opt$base, path), handle = curl::new_handle(ssl_verifypeer = FALSE, ssl_verifyhost = FALSE))
    if (res$status_code != 200) stop("GET ", path, " answered ", res$status_code, call. = FALSE)
    rawToChar(res$content)
  }

  html  <- get("/")
  found <- unique(regmatches(html, gregexpr("/www/[A-Za-z0-9_./-]+", html))[[1]])
  todo  <- grep("\\.js$", found, value = TRUE)

  while (length(todo) > 0) {
    path    <- todo[[1]]
    todo    <- todo[-1]
    text    <- get(path)
    imports <- regmatches(text, gregexpr("from\\s+['\"](\\.{1,2}/[A-Za-z0-9_./-]+\\.js)['\"]", text))[[1]]
    imports <- sub("^from\\s+['\"]", "", sub("['\"]$", "", imports))
    for (import in imports) {
      full <- resolve_path(dirname(path), import)
      if (!full %in% found) { found <- c(found, full); todo <- c(todo, full) }
    }
  }

  found
}

# "/www/js/pages" and "../api.js" make "/www/js/api.js".
resolve_path <- function (dir, relative) {
  parts <- character(0)
  for (part in strsplit(paste0(dir, "/", relative), "/", fixed = TRUE)[[1]]) {
    if (part %in% c("", ".")) next
    if (part == "..") parts <- utils::head(parts, -1) else parts <- c(parts, part)
  }
  paste0("/", paste(parts, collapse = "/"))
}

new_person <- function (id, project) {
  person <- new.env()
  person$id      <- id
  person$project <- project
  person$cookie  <- NULL
  person$key     <- NULL
  person$depth   <- NULL
  person$busy    <- FALSE
  person
}

person_headers <- function (person) c(
  if (!is.null(person$cookie)) c(Cookie = paste0("auth_token=", person$cookie)),
  if (!is.null(person$key))    c("x-session-key" = person$key) )

# Start a session, as the page does when it loads. `then()` runs afterwards.
start_session <- function (person, then = function () NULL) {
  send(
    kind = "session init", method = "POST", url = paste0(opt$base, "/api/session/init"), who = person$id,
    body = list(access_key = person$project),
    headers = if (is.null(person$cookie)) character(0) else c(Cookie = paste0("auth_token=", person$cookie)),
    done = function (status, content, headers) {
      if (status == 200L) {
        cookie <- header_value(headers, "set-cookie")
        cookie <- cookie[startsWith(cookie, "auth_token=")]
        if (length(cookie) > 0) person$cookie <- sub("^auth_token=([^;]*).*$", "\\1", cookie[[1]])
        person$key   <- header_value(headers, "x-session-key")[[1]]
        person$depth <- json_of(content)$BIOM$depth
      }
      then()
    })
}

# Load the page: index.html, every static file, the session and the schema.
# The time from the first request to the last answer is one "page load".
load_page <- function (person, then) {

  began   <- now()
  pending <- length(static_files) + 2L

  arrived <- function (...) {
    pending <<- pending - 1L
    if (pending > 0) return (invisible(NULL))
    records$rows[[length(records$rows) + 1L]] <- list(
      phase = phase, kind = "page load (whole)", who = person$id, sent = round(began, 3),
      status = if (is.null(person$key)) 0L else 200L, seconds = round(now() - began, 4),
      queue_ms = NA_real_, job_ms = NA_real_, bytes = NA_integer_ )
    then()
  }

  send("page", "GET", paste0(opt$base, "/", person$project), who = person$id, done = function (...) {
    for (path in static_files)
      send("static file", "GET", paste0(opt$base, path), who = person$id, done = arrived)
    send("schema", "POST", paste0(opt$base, "/api/schema"), body = "{}", headers = c("Content-Type" = "application/json"), who = person$id, done = arrived)
    start_session(person, arrived)
  })
}

# One thing a person does on a project page, then `then()`.
act <- function (person, then) {

  if (is.null(person$key)) return (start_session(person, then))

  retry_session <- function (status) {
    # 401: the session is gone (it was replaced at sign-in). Start another.
    if (status == 401L) { person$key <- NULL }
    then()
  }

  if (runif(1) < 0.8) {
    plot <- plot_request(person$project)
    send(
      kind = plot$kind, method = "POST", url = paste0(opt$base, "/api/plot"), who = person$id,
      headers = person_headers(person),
      body = list(plot_fn = plot$fn, plot_args = plot$args, depth = person$depth, attrs = TRUE),
      done = function (status, ...) retry_session(status) )
  } else {
    table <- sample(c("metadata", "taxonomy"), 1)
    send(
      kind = paste("table", table), method = "POST", url = paste0(opt$base, "/api/", table, "/table"), who = person$id,
      headers = person_headers(person),
      body = list(draw = 1, start = sample(0:3, 1) * 25, length = 25),
      done = function (status, ...) retry_session(status) )
  }
}

# Browse until `until` (seconds on this script's clock): act, think, repeat.
browse <- function (person, until, left) {
  step <- function () {
    if (now() >= until) return (left())
    act(person, function () after(rexp(1, 1 / opt$think), step))
  }
  step()
}


# Phases -----------------------------------------------------------------------

people <- list()

# Everyone opens the page within ten seconds, then browses.
phase_browse <- function (seconds) {

  phase <<- "browse"
  until <- now() + seconds
  gone  <- 0L

  for (i in seq_len(opt$users)) local({
    person <- new_person(i, names(projects)[[1L + (i %% length(projects))]])
    people[[i]] <<- person
    after(runif(1, 0, min(10, seconds / 4)), function () {
      load_page(person, function () browse(person, until, function () gone <<- gone + 1L))
    })
  })

  # Something only this script knows the time of: does the server still
  # answer quickly while its workers are busy? A request no worker is
  # needed for, every half second.
  probe <- new_person(0L, "hmp50")
  start_session(probe, function () {
    beat <- function () {
      if (now() >= until) return (invisible(NULL))
      send("heartbeat (probe)", "POST", paste0(opt$base, "/api/session/heartbeat"), body = "{}",
           headers = c(person_headers(probe), "Content-Type" = "application/json"), who = 0L)
      after(0.5, beat)
    }
    beat()
  })

  # Part-way through, one more person starts many jobs at once: exports,
  # which do not replace each other as a tab's plots do.
  if (opt$flood > 0) after(seconds / 2, function () {
    flooder <- new_person(-1L, "hmp50")
    start_session(flooder, function () {
      for (i in seq_len(opt$flood))
        send("flood export", "POST", paste0(opt$base, "/api/project/export"), who = -1L,
             headers = person_headers(flooder),
             body = list(what = "beta", method = sample(c("bray", "jaccard", "euclidean", "manhattan"), 1), sample_set = "rare"))
    })
  })

  run_until(function () gone >= opt$users && now() >= until)
  # Let the stragglers finish (a queued plot, the flood).
  run_until(function () length(curl::multi_list(pool)) == 0 || now() >= until + 120)
}


# AI apps: each calls make_plot several times at once, waits for all the
# answers, and does it again. Only a server without accounts has /mcp.
phase_agents <- function () {

  phase <<- "agents"
  left  <- opt$agents

  mcp_call <- function (id, agent, done) {
    arguments <- list(
      project    = "hmp50",
      `function` = "adiv_boxplot",
      args       = list(x = "Body Site", stat.by = "Body Site", adiv = sample(c("shannon", "simpson", "observed", "chao1"), 1)),
      depth      = sample(600:1183, 1) )
    send(
      kind = "mcp make_plot", method = "POST", url = paste0(opt$base, "/mcp"), who = agent,
      headers = c("MCP-Protocol-Version" = "2026-07-28", "Mcp-Method" = "tools/call", "Mcp-Name" = "make_plot"),
      body = list(jsonrpc = "2.0", id = id, method = "tools/call", params = list(
        name = "make_plot", arguments = arguments,
        `_meta` = list(
          "io.modelcontextprotocol/protocolVersion"    = "2026-07-28",
          "io.modelcontextprotocol/clientInfo"         = list(name = "atima-loadtest", version = "1.0"),
          "io.modelcontextprotocol/clientCapabilities" = structure(list(), names = character(0)) ))),
      done = function (status, content, ...) {
        # A refusal (a full queue, too many at once) is a result that says so.
        result <- json_of(content)$result
        if (status == 200L && isTRUE(result$isError))
          records$rows[[length(records$rows)]]$status <- 299L
        done()
      })
  }

  for (a in seq_len(opt$agents)) local({
    agent <- 1000L + a
    round <- function (r) {
      if (r > opt$rounds) { left <<- left - 1L; return (invisible(NULL)) }
      waiting <- opt$calls
      for (i in seq_len(opt$calls))
        mcp_call(i, agent, function () {
          waiting <<- waiting - 1L
          if (waiting == 0) after(1, function () round(r + 1L))
        })
    }
    round(1L)
  })

  run_until(function () left == 0)
}


# People sign in, all at once, through the mock provider (whose answer can
# be made slow: MOCK_DELAY), while a probe keeps asking the server something
# quick. If sign-in holds the server up, the probe's times show it.
phase_signin <- function () {

  phase <<- "signin"
  left  <- opt$signins
  stop_probe <- FALSE

  probe <- new_person(0L, "hmp50")
  start_session(probe, function () {
    beat <- function () {
      if (stop_probe) return (invisible(NULL))
      send("heartbeat (probe)", "POST", paste0(opt$base, "/api/session/heartbeat"), body = "{}",
           headers = c(person_headers(probe), "Content-Type" = "application/json"), who = 0L)
      after(0.2, beat)
    }
    beat()
  })

  location <- function (headers) header_value(headers, "location")[[1]]
  path_of  <- function (url) sub("^[a-z]+://[^/]+", "", url)

  sign_in <- function (i) {

    person  <- new_person(2000L + i, "hmp50")
    finish  <- function () left <<- left - 1L

    start_session(person, function () {
      send("sign-in: start", "GET", paste0(opt$base, "/auth/login?return_to=/"), who = person$id,
           headers = person_headers(person)["Cookie"], done = function (status, content, headers) {

        if (status != 302L) return (finish())

        login  <- header_value(headers, "set-cookie")
        login  <- sub("^oidc_login=([^;]*).*$", "\\1", login[startsWith(login, "oidc_login=")][[1]])
        target <- paste0(opt$issuer, path_of(location(headers)), "&as=load-test-", i)

        send("sign-in: provider page", "GET", target, who = person$id, done = function (status, content, headers) {

          if (status != 302L) return (finish())

          # Back to atima, which now asks the provider for the token.
          send("sign-in: callback", "GET", paste0(opt$base, path_of(location(headers))), who = person$id,
               headers = c(Cookie = paste0("auth_token=", person$cookie, "; oidc_login=", login)),
               done = function (...) finish() )
        })
      })
    })
  }

  after(3, function () for (i in seq_len(opt$signins)) sign_in(i))

  run_until(function () left == 0)
  after(3, function () stop_probe <<- TRUE)
  run_until(function () stop_probe && length(curl::multi_list(pool)) == 0)
}


# Results ----------------------------------------------------------------------

summarise <- function (rows) {

  table <- do.call(rbind, lapply(rows, function (r) as.data.frame(r, stringsAsFactors = FALSE)))
  parts <- split(table, list(table$phase, table$kind), drop = TRUE, sep = "\r")

  q <- function (x, p) if (all(is.na(x))) NA_real_ else round(unname(stats::quantile(x, p, na.rm = TRUE)), 3)

  summary <- do.call(rbind, lapply(parts, function (part) {
    ok <- part[part$status %in% c(200L, 302L, 304L), ]
    data.frame(
      phase     = part$phase[[1]],
      request   = part$kind[[1]],
      n         = nrow(part),
      ok        = nrow(ok),
      other     = paste(sprintf("%s x%d", names(table(part$status[!part$status %in% c(200L, 302L, 304L)])), as.integer(table(part$status[!part$status %in% c(200L, 302L, 304L)]))), collapse = ", "),
      p50_s     = q(ok$seconds, 0.50),
      p90_s     = q(ok$seconds, 0.90),
      p95_s     = q(ok$seconds, 0.95),
      p99_s     = q(ok$seconds, 0.99),
      max_s     = q(ok$seconds, 1),
      wait_p50_s = q(ok$queue_ms, 0.50) / 1000,
      wait_p95_s = q(ok$queue_ms, 0.95) / 1000,
      wait_max_s = q(ok$queue_ms, 1) / 1000,
      run_p50_s  = q(ok$job_ms, 0.50) / 1000,
      run_p95_s  = q(ok$job_ms, 0.95) / 1000,
      stringsAsFactors = FALSE )
  }))

  summary <- summary[order(match(summary$phase, c("browse", "agents", "signin")), summary$request), ]
  rownames(summary) <- NULL

  list(table = table, summary = summary)
}


# Run --------------------------------------------------------------------------

message("Load test '", opt$label, "' against ", opt$base, " (", opt$mode, ")")

static_files <- discover_static()
message("A page load is index.html, ", length(static_files), " static files, the session and the schema.")

if (opt$users > 0 && opt$minutes > 0) {
  message("Browsing: ", opt$users, " people for ", opt$minutes, " minutes, about one action every ", opt$think, " s each.")
  phase_browse(opt$minutes * 60)
}

if (opt$mode == "local" && opt$agents > 0) {
  message("AI apps: ", opt$agents, " x ", opt$rounds, " rounds of ", opt$calls, " make_plot calls at once.")
  phase_agents()
}

if (opt$mode == "shared" && opt$signins > 0 && nzchar(opt$issuer)) {
  message("Signing in: ", opt$signins, " people at once.")
  phase_signin()
}

result  <- summarise(records$rows)
elapsed <- now()

dir.create(opt$out, recursive = TRUE, showWarnings = FALSE)
stem <- file.path(opt$out, paste0(format(started, "%Y%m%dT%H%M%SZ", tz = "UTC"), "-", gsub("[^A-Za-z0-9_-]+", "-", opt$label)))

writeLines(con = paste0(stem, ".json"), jsonlite::toJSON(pretty = TRUE, auto_unbox = TRUE, na = "null", digits = NA, list(
  label        = opt$label,
  started_utc  = format(started, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  seconds      = round(elapsed),
  options      = opt,
  static_files = length(static_files),
  requests     = nrow(result$table),
  summary      = result$summary )))

con <- gzfile(paste0(stem, ".requests.csv.gz"), "w")
utils::write.csv(result$table, con, row.names = FALSE)
close(con)

options(width = 250)
print(result$summary, row.names = FALSE)
message("\nWritten: ", stem, ".json and .requests.csv.gz")
