#______________________________________________________________________________
# The numbers behind the administrators' "Usage" page.
#
# `POST /api/usage/data` answers with everything the page draws for a range
# of days: reach, repeat use, where people come from, what they do, and
# whether the server keeps up. It reads the roll-ups that `usage_rollup()`
# makes (`R/usage.R`), which are brought up to date first, and the raw rows
# only for what cannot be rolled up (run times per function).
#
# The definitions, which the page prints beside the numbers:
#
#   * A person is a row of `users`: someone with an account, or a guest (a
#     browser that has not signed in). A guest who signs in is counted as
#     the account from then on, not as a second person.
#   * A person was "seen" on a day if they did anything that day, and
#     "active" if they completed at least one analysis: a plot, a
#     statistics table, a clustering, a rarefaction, an export, an upload
#     or an import (`usage_analyses`). Looking at a page is not being
#     active.
#   * Administrators, crawlers, load tests and health checks are left out
#     of every count and listed apart (`usage_classes`).
#   * Waiting times cover every job, whoever ran it, load tests included:
#     they are about the server, not about people.
#______________________________________________________________________________


# The rule behind the sentence at the top of the page: the server is not
# keeping up if, on more than `days` of the last `window` days, one job in
# twenty waited longer than `wait_ms` for a worker.
usage_rule <- list(window = 30L, days = 3L, wait_ms = 5000)

# Rows of a ranked list sent to the page.
usage_top <- 100L


#______________________________________________________________________________
#' `POST /api/usage/data`: the numbers for a range of days.
#'
#' @param from,to  The first and last day, `"YYYY-MM-DD"` (UTC). By default
#'                 the 365 days that end today.
#' @return A list; see `usage_report()`.
#' @noRd
api_usage_data <- function (REQ, from = NULL, to = NULL) {

  if (!usage_on(REQ[['CONFIG']]))
    stop_not_found("This server does not record its use.")

  now   <- Sys.time()
  today <- as.Date(usage_day(now))

  as_day <- function (text, default) {
    if (is.null(text)) return (default)
    day <- tryCatch(as.Date(text, format = "%Y-%m-%d"), error = function (e) NA)
    if (is.na(day)) stop_user("That is not a date.")
    day
  }

  to   <- as_day(to, today)
  from <- as_day(from, to - 364L)

  if (from > to) stop_user("The range ends before it starts.")
  if (as.integer(to - from) > 3660L) stop_user("The range is longer than ten years.")

  usage_rollup(REQ[['DB']], now)

  report <- usage_report(REQ[['DB']], format(from), format(to))

  report[['range']][['today']]        <- unbox(format(today))
  report[['range']][['usage_months']] <- unbox(as.integer(REQ[['CONFIG']][['usage_months']] %||% 25L))
  report[['range']][['lookup']]       <- unbox(length(REQ[['GEO']]) > 0)

  report
}


#______________________________________________________________________________
#' Everything the Usage page shows for a range of days.
#'
#' @param from,to  The first and last day, as `"YYYY-MM-DD"`.
#' @return `list(range, reach, repeats, where, what, capacity, classes,
#'         summary)`. Tables are data frames, one row per bar or point;
#'         single numbers are unboxed.
#' @noRd
usage_report <- function (DB, from, to) {

  n <- 0L
  q <- function (sql, ...) {
    n <<- n + 1L
    db_query(DB, sql, paste0("URep", n), if (...length() > 0) list(...), simplify = FALSE)
  }
  one <- function (sql, ...) {
    value <- q(sql, ...)[[1]]
    if (length(value) != 1 || is.na(value)) 0 else value
  }

  day_after <- format(as.Date(to) + 1L)
  back      <- function (days) format(as.Date(to) - days)

  seen_in   <- "class = 'user'"
  active_in <- "class = 'user' AND analyses > 0"
  done      <- "class = 'user' AND outcome = 'done'"
  kinds     <- paste0("'", usage_analyses, "'", collapse = ", ")


  #________________________________________________________
  # Reach: how many people, and how that changes.
  #________________________________________________________
  windows <- c(d7 = 7L, d30 = 30L, d90 = 90L, d365 = 365L)

  count_since <- function (where, days) one(
    paste("SELECT COUNT(DISTINCT user_id) FROM usage_person_days WHERE", where, "AND day > ? AND day <= ?"), back(days), to )

  active <- c(lapply(windows, function (d) unbox(count_since(active_in, d))), list(
    all = unbox(one(paste("SELECT COUNT(DISTINCT user_id) FROM usage_person_days WHERE", active_in, "AND day <= ?"), to)) ))

  seen <- c(lapply(windows, function (d) unbox(count_since(seen_in, d))), list(
    all = unbox(one(paste("SELECT COUNT(DISTINCT user_id) FROM usage_person_days WHERE", seen_in, "AND day <= ?"), to)) ))

  by_day <- q(paste(
    "SELECT day, COUNT(*) AS seen, SUM(analyses > 0) AS active FROM usage_person_days",
    "WHERE", seen_in, "AND day BETWEEN ? AND ? GROUP BY day ORDER BY day" ), from, to)

  # A week is named by its Monday.
  by_week <- q(paste(
    "SELECT date(day, 'weekday 0', '-6 days') AS week, COUNT(DISTINCT user_id) AS seen,",
    "  COUNT(DISTINCT CASE WHEN analyses > 0 THEN user_id END) AS active",
    "FROM usage_person_days WHERE", seen_in, "AND day BETWEEN ? AND ? GROUP BY week ORDER BY week" ), from, to)

  by_month <- q(paste(
    "SELECT substr(day, 1, 7) AS month, COUNT(DISTINCT user_id) AS seen,",
    "  COUNT(DISTINCT CASE WHEN analyses > 0 THEN user_id END) AS active,",
    "  COUNT(DISTINCT CASE WHEN analyses > 0 AND is_account = 1 THEN user_id END) AS accounts,",
    "  COUNT(DISTINCT CASE WHEN analyses > 0 AND ui  > 0 THEN user_id END) AS browser,",
    "  COUNT(DISTINCT CASE WHEN analyses > 0 AND mcp > 0 THEN user_id END) AS apps",
    "FROM usage_person_days WHERE", seen_in, "AND day BETWEEN ? AND ? GROUP BY month ORDER BY month" ), from, to)

  # The month each person was first active in, over all time: who is new in
  # a month, and how many there have been so far.
  firsts <- q(paste(
    "SELECT substr(first, 1, 7) AS month, COUNT(*) AS n FROM (",
    "  SELECT MIN(day) AS first FROM usage_person_days WHERE", active_in, "AND day <= ? GROUP BY user_id)",
    "GROUP BY month ORDER BY month" ), to)

  by_month[['fresh']]      <- vapply(by_month[['month']], function (m) sum(firsts[['n']][firsts[['month']] == m]), numeric(1))
  by_month[['returning']]  <- by_month[['active']] - by_month[['fresh']]
  by_month[['cumulative']] <- vapply(by_month[['month']], function (m) sum(firsts[['n']][firsts[['month']] <= m]), numeric(1))

  reach <- list(
    active     = active,
    seen       = seen,
    registered = unbox(one("SELECT COUNT(*) FROM users WHERE is_guest = 0")),
    by_day     = by_day,
    by_week    = by_week,
    by_month   = by_month )


  #________________________________________________________
  # Repeat use: do the people who try it come back?
  #________________________________________________________
  cohorts <- q(paste(
    "SELECT f.month AS cohort, substr(d.day, 1, 7) AS month, COUNT(DISTINCT d.user_id) AS n",
    "FROM usage_person_days d JOIN (",
    "  SELECT user_id, substr(MIN(day), 1, 7) AS month FROM usage_person_days WHERE", active_in, "GROUP BY user_id",
    ") f ON f.user_id = d.user_id",
    "WHERE d.class = 'user' AND d.analyses > 0 AND f.month >= ? AND f.month <= ? AND d.day <= ?",
    "GROUP BY cohort, substr(d.day, 1, 7) ORDER BY cohort, month" ), substr(from, 1, 7), substr(to, 1, 7), to)

  days_active <- q(paste(
    "SELECT days, COUNT(*) AS users FROM (",
    "  SELECT COUNT(*) AS days FROM usage_person_days WHERE", active_in, "AND day > ? AND day <= ? GROUP BY user_id)",
    "GROUP BY days ORDER BY days" ), back(90L), to)

  repeats <- list(cohorts = cohorts, days_active = days_active)


  #________________________________________________________
  # Where from: the people who were active in the range.
  #________________________________________________________
  people <- paste(
    "FROM usage_people WHERE user_id IN (",
    "  SELECT user_id FROM usage_person_days WHERE", active_in, "AND day BETWEEN ? AND ?)" )

  ranked <- function (column) {
    stopifnot(column %in% c("country", "network", "affiliation", "provider"))
    q(sprintf("SELECT %s AS name, COUNT(*) AS users %s AND %s IS NOT NULL GROUP BY %s ORDER BY users DESC, name",
      column, people, column, column), from, to)
  }

  countries    <- ranked("country")
  networks     <- ranked("network")
  affiliations <- ranked("affiliation")
  providers    <- ranked("provider")

  # A provider is shown by its host name.
  if (nrow(providers) > 0) {
    providers[['name']] <- sub("/.*$", "", sub("^https?://", "", providers[['name']]))
    providers <- stats::aggregate(users ~ name, data = providers, FUN = sum)
    providers <- providers[order(-providers[['users']], providers[['name']]),, drop = FALSE]
    rownames(providers) <- NULL
  }

  arrivals <- paste("FROM usage_daily_arrivals WHERE class = 'user' AND day BETWEEN ? AND ?")

  where <- list(
    countries      = utils::head(countries, usage_top),
    n_countries    = unbox(nrow(countries)),
    networks       = utils::head(networks, usage_top),
    n_networks     = unbox(nrow(networks)),
    affiliations   = utils::head(affiliations, usage_top),
    n_affiliations = unbox(nrow(affiliations)),
    providers      = providers,
    placed         = unbox(one(paste("SELECT COUNT(*)", people, "AND country IS NOT NULL"), from, to)),
    people         = unbox(one(paste("SELECT COUNT(*)", people), from, to)),
    visits         = unbox(one(paste("SELECT SUM(n)", arrivals), from, to)),
    referred       = unbox(one(paste("SELECT SUM(n)", arrivals, "AND ref_host IS NOT NULL"), from, to)),
    sites          = q(paste(
      "SELECT ref_host AS name, SUM(n) AS visits", arrivals, "AND ref_host IS NOT NULL",
      "GROUP BY ref_host ORDER BY visits DESC, name LIMIT ?" ), from, to, usage_top),
    pages          = q(paste(
      "SELECT ref_host || ref_path AS name, SUM(n) AS visits", arrivals, "AND ref_path IS NOT NULL",
      "GROUP BY ref_host, ref_path ORDER BY visits DESC, name LIMIT ?" ), from, to, usage_top) )


  #________________________________________________________
  # What for: what people did, and through what.
  #________________________________________________________
  actions <- paste("FROM usage_daily_actions WHERE", done, "AND day BETWEEN ? AND ?")

  what <- list(

    areas = q(paste(
      "SELECT substr(day, 1, 7) AS month, area, SUM(n) AS n", actions, "AND area IS NOT NULL",
      "GROUP BY month, area ORDER BY month, area" ), from, to),

    functions = q(paste(
      "SELECT fn, area, SUM(n) AS n,",
      "  SUM(CASE WHEN interface = 'ui'  THEN n ELSE 0 END) AS browser,",
      "  SUM(CASE WHEN interface = 'mcp' THEN n ELSE 0 END) AS apps",
      actions, "AND fn IS NOT NULL GROUP BY fn, area ORDER BY n DESC, fn" ), from, to),

    interfaces = q(paste(
      "SELECT substr(day, 1, 7) AS month,",
      "  SUM(CASE WHEN interface = 'ui'  THEN n ELSE 0 END) AS browser,",
      "  SUM(CASE WHEN interface = 'mcp' THEN n ELSE 0 END) AS apps",
      actions, "AND kind IN (", kinds, ") GROUP BY month ORDER BY month" ), from, to),

    apps = q(paste(
      "SELECT COALESCE(app, '(not named)') AS name, SUM(n) AS actions", actions, "AND interface = 'mcp'",
      "GROUP BY name ORDER BY actions DESC, name LIMIT ?" ), from, to, usage_top),

    kinds = q(paste(
      "SELECT substr(day, 1, 7) AS month, kind, SUM(n) AS n", actions,
      "GROUP BY month, kind ORDER BY month, kind" ), from, to),

    outcomes = q(paste(
      "SELECT outcome, SUM(n) AS n FROM usage_daily_actions WHERE class = 'user' AND day BETWEEN ? AND ?",
      "GROUP BY outcome ORDER BY n DESC" ), from, to) )


  #________________________________________________________
  # Capacity: is the server still big enough?
  #________________________________________________________
  days <- q("SELECT * FROM usage_daily WHERE day BETWEEN ? AND ? ORDER BY day", from, to)

  load <- q(paste(
    "SELECT substr(hour, 1, 10) AS day, SUM(busy_sum) * 1.0 / SUM(samples) AS busy, MAX(busy_max) AS busy_max,",
    "  MAX(queue_max) AS queue_max, MAX(workers) AS workers, MAX(disk_used) AS disk_used",
    "FROM usage_hours WHERE samples > 0 AND hour >= ? AND hour < ? GROUP BY day ORDER BY day" ), from, day_after)

  hours <- q(paste(
    "SELECT hour, busy_sum * 1.0 / samples AS busy, busy_max, queue_max, workers",
    "FROM usage_hours WHERE samples > 0 AND hour >= ? AND hour < ? ORDER BY hour" ), max(from, back(13L)), day_after)

  # Day of the week (0 is Sunday) by hour of the day, in UTC.
  heat <- q(paste(
    "SELECT CAST(strftime('%w', substr(hour, 1, 10)) AS INTEGER) AS weekday, CAST(substr(hour, 12, 2) AS INTEGER) AS hour,",
    "  SUM(busy_sum) * 1.0 / SUM(samples) AS busy, MAX(queue_max) AS queue_max",
    "FROM usage_hours WHERE samples > 0 AND hour >= ? AND hour < ? GROUP BY weekday, substr(hour, 12, 2)" ), from, day_after)

  disk <- q(paste(
    "SELECT hour, disk_used, disk_free FROM usage_hours",
    "WHERE disk_used IS NOT NULL AND hour < ? ORDER BY hour DESC LIMIT 1" ), day_after)

  timed <- q(paste(
    "SELECT COALESCE(fn, kind) AS name, run_ms, queue_ms FROM usage_events",
    "WHERE at_utc >= ? AND at_utc < ? AND run_ms IS NOT NULL" ), paste(from, "00:00:00"), paste(day_after, "00:00:00"))

  run_times <- if (nrow(timed) == 0) data.frame(name = character(0)) else {
    groups <- split(timed[['run_ms']], timed[['name']])
    table  <- data.frame(
      name   = names(groups),
      n      = vapply(groups, length, integer(1)),
      median = vapply(groups, stats::median, numeric(1)),
      high   = vapply(groups, stats::quantile, numeric(1), probs = 0.95, names = FALSE),
      stringsAsFactors = FALSE )
    table <- table[order(-table[['high']]),, drop = FALSE]
    rownames(table) <- NULL
    table
  }

  recent <- q("SELECT wait_high, busy, jobs FROM usage_daily WHERE day > ? AND day <= ?", back(usage_rule[['window']]), to)
  slow   <- sum(recent[['wait_high']] > usage_rule[['wait_ms']], na.rm = TRUE)
  full   <- sum(recent[['busy']] > 0)

  verdict <- list(
    state     = unbox(
      if (sum(recent[['jobs']]) == 0)       "none"
      else if (slow > usage_rule[['days']]) "slow"
      else if (full > usage_rule[['days']]) "full"
      else                                  "ok" ),
    slow_days = unbox(slow),
    full_days = unbox(full),
    window    = unbox(usage_rule[['window']]),
    days      = unbox(usage_rule[['days']]),
    wait_ms   = unbox(usage_rule[['wait_ms']]) )

  capacity <- list(
    verdict   = verdict,
    days      = days,
    load      = load,
    hours     = hours,
    heat      = heat,
    run_times = run_times,
    disk      = if (nrow(disk) == 1) list(
      hour = unbox(disk[['hour']]),
      used = unbox(disk[['disk_used']]),
      free = unbox(if (is.na(disk[['disk_free']])) NA else disk[['disk_free']]) ) )


  #________________________________________________________
  # Who is left out of the counts above, and how much they did.
  #________________________________________________________
  per_class <- function (sql) {
    found <- q(sql, from, to)
    stats::setNames(as.numeric(found[[2]]), found[[1]])[usage_classes]
  }

  requests <- per_class("SELECT class, SUM(requests) FROM usage_requests WHERE day BETWEEN ? AND ? GROUP BY class")
  acts     <- per_class("SELECT class, SUM(n) FROM usage_daily_actions WHERE day BETWEEN ? AND ? GROUP BY class")
  persons  <- per_class("SELECT class, COUNT(DISTINCT user_id) FROM usage_person_days WHERE day BETWEEN ? AND ? GROUP BY class")

  zero <- function (x) { x[is.na(x)] <- 0; unname(x) }

  classes <- data.frame(
    class    = usage_classes,
    requests = zero(requests),
    actions  = zero(acts),
    people   = zero(persons),
    stringsAsFactors = FALSE )


  #________________________________________________________
  # The period in a few numbers, for a report.
  #________________________________________________________
  in_range  <- paste("FROM usage_person_days WHERE", active_in, "AND day BETWEEN ? AND ?")
  count_of  <- function (kind) one(paste("SELECT SUM(n)", actions, "AND kind = ?"), from, to, kind)
  waits     <- timed[['queue_ms']][!is.na(timed[['queue_ms']])]

  summary <- lapply(FUN = unbox, list(
    active       = one(paste("SELECT COUNT(DISTINCT user_id)", in_range), from, to),
    accounts     = one(paste("SELECT COUNT(DISTINCT user_id)", in_range, "AND is_account = 1"), from, to),
    seen         = one(paste("SELECT COUNT(DISTINCT user_id) FROM usage_person_days WHERE", seen_in, "AND day BETWEEN ? AND ?"), from, to),
    fresh        = one(paste(
      "SELECT COUNT(*) FROM (SELECT MIN(day) AS first FROM usage_person_days WHERE", active_in, "GROUP BY user_id)",
      "WHERE first BETWEEN ? AND ?" ), from, to),
    came_back    = one(paste("SELECT COUNT(*) FROM (SELECT user_id", in_range, "GROUP BY user_id HAVING COUNT(*) > 1)"), from, to),
    browser      = one(paste("SELECT COUNT(DISTINCT user_id)", in_range, "AND ui > 0"), from, to),
    apps         = one(paste("SELECT COUNT(DISTINCT user_id)", in_range, "AND mcp > 0"), from, to),
    countries    = nrow(countries),
    networks     = nrow(networks),
    affiliations = nrow(affiliations),
    analyses     = one(paste("SELECT SUM(n)", actions, "AND kind IN (", kinds, ")"), from, to),
    plots        = count_of("plot"),
    stats        = count_of("stats"),
    uploads      = count_of("upload"),
    exports      = count_of("export"),
    published    = count_of("publish"),
    imports      = count_of("import"),
    visits       = one(paste("SELECT SUM(n)", arrivals), from, to),
    jobs         = length(waits),
    wait_median  = if (length(waits) > 0) stats::median(waits) else NA,
    wait_high    = if (length(waits) > 0) stats::quantile(waits, 0.95, names = FALSE) else NA ))

  first_day <- q("SELECT MIN(day) AS day FROM usage_daily")[['day']]

  list(
    range    = list(
      from      = unbox(from),
      to        = unbox(to),
      first_day = unbox(if (length(first_day) == 1 && !is.na(first_day)) first_day else NA) ),
    reach    = reach,
    repeats  = repeats,
    where    = where,
    what     = what,
    capacity = capacity,
    classes  = classes,
    summary  = summary )
}
