#______________________________________________________________________________
# Usage monitoring: what use of a shared server is recorded.
#
# A shared server (`auth = "oidc"`) keeps counts of its use, so that its
# administrators can say how many researchers use it, from where and for
# what, and whether the server is still big enough (`R/usage-report.R`, the
# "Usage" page). A local install records nothing: `usage_on()` is false
# there, no table is written and the page's route does not exist.
#
# Everything is recorded in two places and nowhere else: the router
# (`request_done()` calls `usage_record()` for every request) and a timer
# (`usage_start()`, which samples how busy the workers are). Handlers never
# record anything. What a request is, for this purpose, comes from its
# route's declaration (`route(usage = , usage_fn = )`) or, for a tool an AI
# app calls, from the tool's name (`tool_call()` in `R/mcp-tools.R`).
#
# What is written (the tables are described in `inst/sql/008_usage.sql`):
#
#   * An action: when, the user's number, whether through the browser or an
#     AI app (and the app's name), what kind of action, the rbiom function,
#     how it ended, how long it waited for a worker and how long it ran.
#   * A visit: the site the browser was sent from, the country and the
#     owner of the network it came from. Both are looked up in a file on
#     this server (`R/geo.R`); the address itself is not written here.
#   * A request with no browser cookie (a crawler, a script, a first visit):
#     a hash of its address, its user agent and a secret, so that it can be
#     counted once that day. The secret is made new every day and lives in
#     memory only, so the hash cannot be turned back into an address, nor
#     matched with the next day's. The hashes are deleted after two days.
#
# Never written: an address, a name or email address, a project, a file, or
# an argument of a request other than the name of an rbiom function.
#
# The raw rows are kept for `usage_months`. Before that they are counted
# into daily roll-ups (`usage_rollup()`), which are kept: the long charts
# read those.
#______________________________________________________________________________


# The kinds of action. `usage_analyses` are the ones that make a person an
# "active user" on the day they did one: they ran something or brought data.
usage_kinds <- c(
  "visit", "page", "open", "plot", "stats", "table", "clusters", "rarefy", "export", "download",
  "upload", "save", "share", "publish", "import", "manage", "describe", "tool" )

usage_analyses <- c("plot", "stats", "clusters", "rarefy", "export", "upload", "import")

# Whose use a row is. Everything but `user` is left out of the counts and
# shown apart.
usage_classes <- c("user", "admin", "bot", "loadtest", "health", "anonymous")

# User agents of crawlers, link previews and monitors.
usage_bot_pattern <- paste0(
  "bot\\b|bot/|crawl|spider|slurp|preview|scan|monitor|uptime|headless|",
  "facebookexternalhit|embedly|quora link|pingdom|lighthouse|feedfetcher|archive\\.org" )

# What kind of action each tool an AI app can call is.
usage_tool_kinds <- c(
  list_projects    = "describe", describe_project = "describe", describe_function = "describe",
  run_stats        = "stats",    make_plot        = "plot",     export            = "export",
  upload_project   = "upload",   upload_component = "upload",   upload_status     = "describe",
  edit_project     = "save",     add_clusters     = "clusters", set_field_type    = "manage",
  set_level_order  = "manage",   set_group_colors = "manage",   copy_project      = "save",
  find_users       = "describe", list_access      = "describe", share_project     = "share",
  new_share_link   = "share",    publish_project  = "publish",  delete_project    = "manage" )

# The day's secret for hashing visitors without a cookie. In memory only.
usage_env <- new.env(parent = emptyenv())


#______________________________________________________________________________
#' Does this server record its use?
#' @noRd
usage_on <- function (config) {
  identical(config[['auth']], "oidc") && !isFALSE(config[['usage']])
}


#' A day as the tables write it.
#' @noRd
usage_day <- function (time) format(time, "%Y-%m-%d", tz = "UTC")


#______________________________________________________________________________
#' Note what kind of action a request is, as soon as its route is known.
#' @noRd
usage_begin <- function (REQ, route) {
  if (!is.null(route[['usage']]))
    REQ[['USAGE']] <- list(kind = route[['usage']])
  invisible(NULL)
}


#' Note what a request's checked arguments say about it: the rbiom function
#' it names and, for a new visit, where the browser came from. Nothing else
#' of the arguments is looked at.
#' @noRd
usage_args <- function (REQ, route, args) {

  if (is.null(route[['usage']])) return (invisible(NULL))

  fn_arg <- route[['usage_fn']]

  if (!is.null(fn_arg) && is_scalar_character(args[[fn_arg]]))
    REQ[['USAGE']][['fn']] <- args[[fn_arg]]

  if (identical(route[['usage']], "visit") && is_scalar_character(args[['referrer']]))
    REQ[['USAGE']][['referrer']] <- args[['referrer']]

  invisible(NULL)
}


#' Note what a tool call is: the tool decides the kind, and `fn` is the
#' rbiom function it names once that has been checked.
#' @noRd
usage_tool <- function (REQ, tool, fn = NULL) {

  kind <- unname(usage_tool_kinds[tool[['name']]])
  REQ[['USAGE']] <- list(kind = if (length(kind) != 1 || is.na(kind)) "tool" else kind)

  if (is_scalar_character(fn) && fn %in% names(schema_functions))
    REQ[['USAGE']][['fn']] <- fn

  invisible(NULL)
}


#______________________________________________________________________________
#' Whose request this is, for the counts.
#'
#' @return `list(class, is_account)`.
#' @noRd
usage_who <- function (DB, user_id, user_agent, path) {

  agent <- user_agent %||% ""

  class <- if (identical(path, "/api/health")) { "health"
  } else if (startsWith(agent, "atima-loadtest")) { "loadtest"
  } else if (grepl(usage_bot_pattern, agent, ignore.case = TRUE)) { "bot"
  } else { NULL }

  is_account <- FALSE

  if (!is.null(user_id) && !is.na(user_id)) {
    sql <- "SELECT is_guest, is_admin FROM users WHERE user_id = ?"
    row <- db_query(DB, sql, "UWho1", list(user_id), simplify = FALSE)
    if (nrow(row) == 1) {
      is_account <- !isTRUE(row[['is_guest']])
      class      <- class %||% if (isTRUE(row[['is_admin']])) "admin" else "user"
    }
  }

  list(class = class %||% "anonymous", is_account = is_account)
}


#______________________________________________________________________________
#' How a request ended.
#'
#' @param failure  The error that ended it, if one did.
#' @param status   The status of its response.
#' @return One of `done`, `rejected`, `denied`, `replaced`, `cancelled`,
#'         `limited` (too many jobs for one person), `busy` (the queue was
#'         full), `timeout`, `failed`.
#' @noRd
usage_outcome <- function (failure, status) {

  if (!is.null(failure))
    status <- if (inherits(failure, c("atima_http_error", "mcp_error"))) failure[['status']] else 500L

  status <- as.integer(status %||% 500L)

  if (status < 400L)           return ("done")
  if (status %in% c(401L, 403L)) return ("denied")
  if (status == 409L) {
    message <- if (is.null(failure)) "" else conditionMessage(failure)
    return (if (grepl("replaced", message, fixed = TRUE)) "replaced" else "cancelled")
  }
  if (status == 429L)          return ("limited")
  if (status == 503L)          return ("busy")
  if (status == 504L)          return ("timeout")
  if (status < 500L)           return ("rejected")

  "failed"
}


#______________________________________________________________________________
#' Today's hash for a visitor without a cookie.
#'
#' The secret is made when first needed on a day and replaced when the day
#' changes (or the server restarts). It is never written anywhere.
#' @noRd
usage_visitor_hash <- function (day, ip_address, user_agent) {

  if (!identical(usage_env$day, day)) {
    usage_env$day    <- day
    usage_env$secret <- random_string(48)
  }

  substr(as.character(sha256(paste(usage_env$secret, ip_address %||% "", user_agent %||% "", sep = "\n"))), 1L, 24L)
}


#______________________________________________________________________________
#' The site a browser was sent from, as recorded: host and path, without
#' the query string. Nothing for an address that is not a web address, or
#' that is this server's own.
#'
#' @return `list(host, path)` or `NULL`.
#' @noRd
usage_referrer <- function (referrer, config = list()) {

  if (!is_scalar_character(referrer) || is.na(referrer)) return (NULL)
  if (!grepl("^https?://", referrer, ignore.case = TRUE)) return (NULL)

  rest <- sub("^https?://", "", referrer, ignore.case = TRUE)
  rest <- sub("[?#].*$", "", rest)
  host <- tolower(sub("/.*$", "", rest))
  host <- sub("^[^@]*@", "", host)
  host <- sub(":[0-9]+$", "", host)
  host <- sub("^www\\.", "", host)
  path <- if (grepl("/", rest, fixed = TRUE)) sub("^[^/]*", "", rest) else ""

  if (!grepl("^[a-z0-9.-]{1,200}$", host) || !grepl(".", host, fixed = TRUE)) return (NULL)

  own <- sub("^www\\.", "", url_host(config[['public_url']] %||% ""))
  if (identical(host, own)) return (NULL)

  path <- gsub("[^\x21-\x7e]", "", path)
  path <- sub("/+$", "", path)

  list(host = host, path = if (nzchar(path)) substr(path, 1L, 200L))
}


#______________________________________________________________________________
#' Record a request that has just been answered. Called by the router for
#' every request; does nothing on a server that records no use. A failure
#' here is logged and never reaches the request.
#'
#' @param REQ      The request environment.
#' @param started  When the request arrived.
#' @param resp     Its response.
#' @noRd
usage_record <- function (REQ, started, resp) {

  if (!usage_on(REQ[['CONFIG']])) return (invisible(NULL))

  tryCatch(
    expr  = usage_write(REQ, started, resp),
    error = function (e) log_event("error", "usage_failed", message = log_truncate(conditionMessage(e), 2000L)) )

  invisible(NULL)
}


#' The writing itself; see `usage_record()`.
#' @noRd
usage_write <- function (REQ, started, resp) {

  DB     <- REQ[['DB']]
  now    <- Sys.time()
  day    <- usage_day(now)
  client <- REQ[['CLIENT']]
  usage  <- REQ[['USAGE']]
  kind   <- usage[['kind']]

  user_id <- REQ[['SESSION']][['user_id']]
  if (length(user_id) != 1 || is.na(user_id)) user_id <- NULL

  who <- usage_who(DB, user_id, client[['user_agent']], REQ[['ROUTE']][['path']])

  sql <- paste0(
    "INSERT INTO usage_requests (day, class, requests) VALUES (?, ?, 1)",
    " ON CONFLICT (day, class) DO UPDATE SET requests = requests + 1" )
  db_query(DB, sql, "UWri1", list(day, who[['class']]))

  if (is.null(kind) || who[['class']] == "health") return (invisible(NULL))

  outcome   <- usage_outcome(REQ[['FAILED']], resp[['status']])
  no_cookie <- is.null(client[['auth_token']])

  # A request that came without a cookie is counted once for the day. If
  # it goes on to start a session, it is a person and is counted as one.
  if (no_cookie && kind %in% c("page", "download", "visit")) {

    visitor <- usage_visitor_hash(day, client[['ip_address']], client[['user_agent']])

    if (kind == "visit") {
      sql <- "UPDATE usage_visitors SET has_session = 1 WHERE day = ? AND visitor = ?"
      db_query(DB, sql, "UWri2", list(day, visitor))
    } else {
      sql <- paste0(
        "INSERT INTO usage_visitors (day, visitor, class, hits) VALUES (?, ?, ?, 1)",
        " ON CONFLICT (day, visitor) DO UPDATE SET hits = hits + 1" )
      db_query(DB, sql, "UWri3", list(day, visitor, who[['class']]))
    }
  }

  # Loading the page is not an action; starting a session on it is.
  if (kind == "page") return (invisible(NULL))

  fn     <- usage[['fn']]
  timing <- REQ[['TIMING']]
  is_mcp <- !is.null(REQ[['CALLER']]) || identical(REQ[['ROUTE']][['path']], "/api/upload")
  app    <- if (is_mcp && is_scalar_character(REQ[['CALLER']][['app']])) substr(REQ[['CALLER']][['app']], 1L, 80L)

  db_insert(
    DB = DB, table = "usage_events", err_code = "UWri4",
    at_utc     = sql_time(now),
    user_id    = user_id,
    class      = who[['class']],
    is_account = who[['is_account']],
    interface  = if (is_mcp) "mcp" else "ui",
    app        = app,
    kind       = kind,
    fn         = fn,
    area       = if (!is.null(fn)) schema_functions[[fn]][['area']],
    outcome    = outcome,
    queue_ms   = if (is.numeric(timing)) unname(timing['queue']),
    run_ms     = if (is.numeric(timing)) unname(timing['job']),
    total_ms   = round(as.numeric(difftime(now, started, units = "secs")) * 1000, 1) )

  if (kind == "visit" && outcome == "done") {

    from  <- usage_referrer(usage[['referrer']], REQ[['CONFIG']])
    place <- geo_lookup(REQ[['GEO']], client[['ip_address']])

    db_insert(
      DB = DB, table = "usage_arrivals", err_code = "UWri5",
      at_utc   = sql_time(now),
      user_id  = user_id,
      class    = who[['class']],
      ref_host = from[['host']],
      ref_path = from[['path']],
      country  = place[['country']],
      network  = place[['network']] )
  }

  invisible(NULL)
}


#______________________________________________________________________________
#' A guest has signed in and become a user: what the guest did counts as
#' the user's, so that one person is not counted as two.
#' @noRd
usage_adopt <- function (DB, guest_id, user_id) {

  ids <- list(user_id, guest_id)

  db_query(DB, "UPDATE usage_events   SET user_id = ? WHERE user_id = ?", "UAdo1", ids)
  db_query(DB, "UPDATE usage_arrivals SET user_id = ? WHERE user_id = ?", "UAdo2", ids)

  # A day on which both were seen keeps the user's row and gains the guest's counts.
  sql <- paste0(
    "UPDATE usage_person_days SET",
    "  actions = usage_person_days.actions + g.actions, analyses = usage_person_days.analyses + g.analyses,",
    "  ui      = usage_person_days.ui      + g.ui,      mcp      = usage_person_days.mcp      + g.mcp",
    " FROM (SELECT day, actions, analyses, ui, mcp FROM usage_person_days WHERE user_id = ?) g",
    " WHERE usage_person_days.user_id = ? AND usage_person_days.day = g.day" )
  db_query(DB, sql, "UAdo3", list(guest_id, user_id))

  sql <- paste0(
    "UPDATE usage_person_days SET user_id = ?, is_account = 1",
    " WHERE user_id = ? AND day NOT IN (SELECT day FROM usage_person_days WHERE user_id = ?)" )
  db_query(DB, sql, "UAdo4", list(user_id, guest_id, user_id))
  db_query(DB, "DELETE FROM usage_person_days WHERE user_id = ?", "UAdo5", list(guest_id))

  guest <- db_query(DB, "SELECT * FROM usage_people WHERE user_id = ?", "UAdo6", list(guest_id), simplify = FALSE)

  if (nrow(guest) == 1) {
    sql <- paste0(
      "INSERT INTO usage_people (user_id, first_day, class, is_account, country, network) VALUES (?, ?, ?, 1, ?, ?)",
      " ON CONFLICT (user_id) DO UPDATE SET first_day = MIN(first_day, excluded.first_day)" )
    db_query(DB, sql, "UAdo7", list(user_id, guest[['first_day']], guest[['class']], guest[['country']], guest[['network']]))
    db_query(DB, "DELETE FROM usage_people WHERE user_id = ?", "UAdo8", list(guest_id))
  }

  invisible(NULL)
}


#______________________________________________________________________________
#' Count the raw rows of the days that are not rolled up yet into the
#' roll-up tables. Today is always done again, so the roll-ups are never
#' more than one run behind.
#'
#' @param now  The current time; tests pass other values.
#' @return The days that were rolled up, invisibly.
#' @noRd
usage_rollup <- function (DB, now = Sys.time()) {

  today <- as.Date(usage_day(now))

  last  <- db_query(DB, "SELECT MAX(day) FROM usage_daily", "URol1")
  first <- db_query(DB, paste(
    "SELECT MIN(day) FROM (SELECT MIN(substr(at_utc, 1, 10)) AS day FROM usage_events",
    "UNION ALL SELECT MIN(day) FROM usage_requests UNION ALL SELECT MIN(day) FROM usage_visitors)" ), "URol2")

  from <- if (!is.null(last) && !is.na(last)) { as.Date(last)
  } else if (!is.null(first) && !is.na(first)) { as.Date(first)
  } else { today }

  if (from > today) from <- today

  days <- format(seq(from, today, by = "day"))

  for (day in days)
    db_transaction(DB, usage_rollup_day(DB, day))

  invisible(days)
}


#' Roll up one day; see `usage_rollup()`.
#' @noRd
usage_rollup_day <- function (DB, day) {

  start <- paste(day, "00:00:00")
  end   <- paste(format(as.Date(day) + 1), "00:00:00")
  span  <- list(start, end)

  db_query(DB, "DELETE FROM usage_daily_actions  WHERE day = ?", "URDay1", list(day))
  db_query(DB, "DELETE FROM usage_daily_arrivals WHERE day = ?", "URDay2", list(day))
  db_query(DB, "DELETE FROM usage_person_days    WHERE day = ?", "URDay3", list(day))

  sql <- paste0(
    "INSERT INTO usage_daily_actions (day, class, interface, app, kind, fn, area, outcome, n)",
    " SELECT ?, class, interface, app, kind, fn, area, outcome, COUNT(*) FROM usage_events",
    " WHERE at_utc >= ? AND at_utc < ? GROUP BY class, interface, app, kind, fn, area, outcome" )
  db_query(DB, sql, "URDay4", c(list(day), span))

  sql <- paste0(
    "INSERT INTO usage_daily_arrivals (day, class, ref_host, ref_path, country, network, n)",
    " SELECT ?, class, ref_host, ref_path, country, network, COUNT(*) FROM usage_arrivals",
    " WHERE at_utc >= ? AND at_utc < ? GROUP BY class, ref_host, ref_path, country, network" )
  db_query(DB, sql, "URDay5", c(list(day), span))

  # One row per person: someone who was seen at all, with how much they did.
  # A person recorded under two classes that day counts under the one that
  # is left out of the counts ("admin" and "bot" sort before "user").
  sql <- paste0(
    "INSERT INTO usage_person_days (day, user_id, class, is_account, actions, analyses, ui, mcp)",
    " SELECT ?, user_id, MIN(class), MAX(is_account),",
    "   SUM(outcome = 'done'),",
    "   SUM(outcome = 'done' AND kind IN (", paste0("'", usage_analyses, "'", collapse = ", "), ")),",
    "   SUM(outcome = 'done' AND interface = 'ui'),",
    "   SUM(outcome = 'done' AND interface = 'mcp')",
    " FROM usage_events WHERE at_utc >= ? AND at_utc < ? AND user_id IS NOT NULL GROUP BY user_id" )
  db_query(DB, sql, "URDay6", c(list(day), span))

  sql <- paste0(
    "INSERT INTO usage_people (user_id, first_day, class, is_account)",
    " SELECT user_id, day, class, is_account FROM usage_person_days WHERE day = ?",
    " ON CONFLICT (user_id) DO UPDATE SET",
    "   class      = excluded.class,",
    "   is_account = MAX(is_account, excluded.is_account),",
    "   first_day  = MIN(first_day, excluded.first_day)" )
  db_query(DB, sql, "URDay7", list(day))

  # Where each person came from: their latest visit of the day that says.
  sql <- paste0(
    "UPDATE usage_people SET country = COALESCE(a.country, usage_people.country), network = COALESCE(a.network, usage_people.network)",
    " FROM (SELECT user_id, country, network, MAX(arrival_id) FROM usage_arrivals",
    "       WHERE at_utc >= ? AND at_utc < ? AND user_id IS NOT NULL AND (country IS NOT NULL OR network IS NOT NULL)",
    "       GROUP BY user_id) a",
    " WHERE usage_people.user_id = a.user_id" )
  db_query(DB, sql, "URDay8", span)

  # For someone with an account: the institution their sign-in provider names.
  sql <- paste0(
    "UPDATE usage_people SET affiliation = u.affiliation",
    " FROM users u",
    " WHERE u.user_id = usage_people.user_id AND u.is_guest = 0",
    "   AND usage_people.user_id IN (SELECT user_id FROM usage_person_days WHERE day = ?)" )
  db_query(DB, sql, "URDay9", list(day))

  # The day as a whole: how long jobs waited, and what was refused.
  sql    <- "SELECT outcome, queue_ms FROM usage_events WHERE at_utc >= ? AND at_utc < ?"
  events <- db_query(DB, sql, "URDay10", span, simplify = FALSE)
  waits  <- events[['queue_ms']][!is.na(events[['queue_ms']])]

  sql      <- "SELECT class, hits FROM usage_visitors WHERE day = ? AND has_session = 0"
  visitors <- db_query(DB, sql, "URDay11", list(day), simplify = FALSE)
  is_bot   <- visitors[['class']] == "bot"

  # The hashes of a day are deleted two days on; a roll-up made after that
  # must not lose what was counted while they were there.
  kept <- db_query(DB, "SELECT visitors, visitor_hits, bots, bot_hits FROM usage_daily WHERE day = ?", "URDay12", list(day), simplify = FALSE)
  seen <- if (nrow(visitors) == 0 && nrow(kept) == 1) as.list(kept) else list(
    visitors     = sum(!is_bot),
    visitor_hits = sum(visitors[['hits']][!is_bot]),
    bots         = sum(is_bot),
    bot_hits     = sum(visitors[['hits']][is_bot]) )

  db_query(DB, "DELETE FROM usage_daily WHERE day = ?", "URDay13", list(day))

  db_insert(
    DB = DB, table = "usage_daily", err_code = "URDay14",
    day          = day,
    jobs         = length(waits),
    wait_median  = if (length(waits) > 0) unname(stats::quantile(waits, 0.50)),
    wait_high    = if (length(waits) > 0) unname(stats::quantile(waits, 0.95)),
    waited_sec   = sum(waits > 1000),
    waited_long  = sum(waits > 10000),
    busy         = sum(events[['outcome']] == "busy"),
    limited      = sum(events[['outcome']] == "limited"),
    timed_out    = sum(events[['outcome']] == "timeout"),
    failed       = sum(events[['outcome']] == "failed"),
    visitors     = seen[['visitors']],
    visitor_hits = seen[['visitor_hits']],
    bots         = seen[['bots']],
    bot_hits     = seen[['bot_hits']] )

  invisible(NULL)
}


#______________________________________________________________________________
#' Delete raw rows that have been kept long enough. The roll-ups stay.
#'
#' @param months  How many months the rows of actions and visits are kept.
#' @return The number of rows deleted.
#' @noRd
usage_expire <- function (DB, months, now = Sys.time()) {

  today  <- as.Date(usage_day(now))
  cutoff <- paste(format(seq(today, by = paste0("-", as.integer(months), " months"), length.out = 2L)[[2]]), "00:00:00")

  db_transaction(DB,
    delete_where(DB, "usage_events",   "at_utc < ?", list(cutoff)) +
    delete_where(DB, "usage_arrivals", "at_utc < ?", list(cutoff)) +
    delete_where(DB, "usage_visitors", "day < ?",    list(format(today - 1L))) )
}


#______________________________________________________________________________
#' Note how busy the workers are, into the row of the current hour.
#'
#' What is counted is CPU cores: those the pool counts as in use, which it
#' measures (`pool_sample()` in `R/jobs.R`), for the jobs and for the web
#' server's own process, out of the cores the server may use (`pool$used`
#' of `pool$cores`). The columns are older than that and still called
#' `busy_sum`, `busy_max` and `workers`.
#'
#' The pool keeps its own high marks between two samples (`pool$peak_used`,
#' `pool$peak_queue`), so a queue that formed and cleared within the minute
#' is still seen. The space used under `data_dir` is measured once an hour.
#'
#' @param pool  The worker pool, or `NULL`.
#' @noRd
usage_sample <- function (DB, config, pool = NULL, now = Sys.time()) {

  hour <- format(now, "%Y-%m-%d %H", tz = "UTC")

  busy    <- as.integer(pool$used %||% 0L)
  workers <- as.integer(pool$cores %||% 0L)
  peak    <- max(busy, as.integer(pool$peak_used %||% 0L))
  queued  <- max(length(pool$queue), as.integer(pool$peak_queue %||% 0L))

  if (!is.null(pool)) {
    pool$peak_used  <- busy
    pool$peak_queue <- length(pool$queue)
  }

  db_transaction(DB, {

    if (db_query(DB, "SELECT COUNT(*) FROM usage_hours WHERE hour = ?", "USam1", list(hour)) == 0) {
      disk <- usage_disk(config[['data_dir']])
      db_insert(DB, "usage_hours", "USam2", hour = hour, disk_used = disk[['used']], disk_free = disk[['free']])
    }

    sql <- paste0(
      "UPDATE usage_hours SET samples = samples + 1, workers = ?, busy_sum = busy_sum + ?,",
      " busy_max = MAX(busy_max, ?), queue_max = MAX(queue_max, ?) WHERE hour = ?" )
    db_query(DB, sql, "USam3", list(workers, busy, peak, queued, hour))
  })

  invisible(NULL)
}


#______________________________________________________________________________
#' The space the files under a directory take, and what is left on its disk.
#'
#' @return `list(used, free)` in bytes; `free` is `NULL` where it cannot be
#'         found out (it is asked of `df`, which Windows does not have).
#' @noRd
usage_disk <- function (dir) {

  if (is.null(dir) || !dir.exists(dir)) return (list(used = NULL, free = NULL))

  files <- list.files(dir, recursive = TRUE, full.names = TRUE, all.files = TRUE)
  used  <- sum(file.size(files), na.rm = TRUE)

  free <- NULL

  if (.Platform[['OS.type']] == "unix")
    free <- tryCatch(
      expr  = {
        out   <- suppressWarnings(system2("df", c("-Pk", shQuote(dir)), stdout = TRUE, stderr = FALSE))
        cells <- strsplit(trimws(out[[length(out)]]), "[[:space:]]+")[[1]]
        kb    <- suppressWarnings(as.numeric(cells[[4]]))
        if (is.na(kb)) NULL else kb * 1024
      },
      error = function (e) NULL )

  list(used = used, free = free)
}


# Seconds between two samples of the workers, and how many samples pass
# between two roll-ups.
usage_interval     <- 60
usage_rollup_every <- 10L


#______________________________________________________________________________
#' Start the timer that samples the workers every minute, and rolls up and
#' expires the raw rows every ten.
#'
#' @param app  `list(db, config, pool)`.
#' @return A function that stops the timer.
#' @noRd
usage_start <- function (app, interval = usage_interval) {

  stopped <- FALSE
  cancel  <- function () NULL
  ticks   <- 0L

  tick <- function () {

    if (stopped) return (invisible(NULL))

    tryCatch(
      expr  = {
        usage_sample(app[['db']], app[['config']], app[['pool']])
        if (ticks %% usage_rollup_every == 0L) {
          usage_rollup(app[['db']])
          usage_expire(app[['db']], app[['config']][['usage_months']] %||% 25L)
        }
      },
      error     = function (e) log_event("error", "usage_failed", message = log_truncate(conditionMessage(e), 2000L)),
      # The server was told to stop while this ran (`R/shutdown.R`).
      interrupt = function (e) shutdown$requested <- TRUE )

    ticks  <<- ticks + 1L
    cancel <<- later::later(tick, interval)
  }

  tick()

  function () {
    stopped <<- TRUE
    cancel()
    invisible(NULL)
  }
}
