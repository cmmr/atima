-- Schema version 8.
--
-- What use of a shared server is recorded (`R/usage.R`), so that its
-- administrators can say how many people use it, from where and for what,
-- and whether the server keeps up. A local install writes none of these.
--
-- No table here holds a network address, a name, an email address, a
-- project, or anything from a request's arguments beyond the name of an
-- rbiom function. `user_id` is the number of a row of `users` at the time;
-- it is deliberately not a foreign key, because the counts must outlast the
-- guest (or account) they were made by.
--
-- Raw rows, deleted after `usage_months`:
--  * usage_events: one row per action (a plot, an upload, an export, ...).
--  * usage_arrivals: one row per visit (a browser tab starting a session):
--    the site it was sent from, the country and the owner of its network.
--  * usage_visitors: requests that came with no browser cookie, told apart
--    for one day by a hash of address, user agent and a secret that is
--    replaced daily and kept in memory only. Rows go after two days.
--
-- Roll-ups, kept:
--  * usage_people: one row per person: when first seen and where from.
--  * usage_person_days: one small row per person per day they did anything,
--    which is what distinct people per week, month or year are counted from.
--  * usage_daily_actions, usage_daily_arrivals: counts per day.
--  * usage_daily: one row per day: waiting times and requests refused.
--  * usage_requests: requests per day and class of caller.
--  * usage_hours: one row per hour: how busy the workers were, and disk.
--
-- `class` says whose use a row is: `user`, or one of those left out of the
-- counts and shown apart: `admin`, `bot`, `loadtest`, `health`, and
-- `anonymous` for a request that belongs to nobody.


-- usage_events ----------------------------------------------------------------

CREATE TABLE usage_events (
  event_id   INTEGER  PRIMARY KEY,
  at_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  user_id    INTEGER      NULL DEFAULT NULL,
  class      TEXT     NOT NULL,
  is_account BOOLEAN  NOT NULL DEFAULT 0,
  interface  TEXT     NOT NULL,
  app        TEXT         NULL DEFAULT NULL,
  kind       TEXT     NOT NULL,
  fn         TEXT         NULL DEFAULT NULL,
  area       TEXT         NULL DEFAULT NULL,
  outcome    TEXT     NOT NULL,
  queue_ms   REAL         NULL DEFAULT NULL,
  run_ms     REAL         NULL DEFAULT NULL,
  total_ms   REAL         NULL DEFAULT NULL
);

CREATE INDEX usage_events_at   ON usage_events (at_utc);
CREATE INDEX usage_events_user ON usage_events (user_id);


-- usage_arrivals --------------------------------------------------------------

CREATE TABLE usage_arrivals (
  arrival_id INTEGER  PRIMARY KEY,
  at_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  user_id    INTEGER      NULL DEFAULT NULL,
  class      TEXT     NOT NULL,
  ref_host   TEXT         NULL DEFAULT NULL,
  ref_path   TEXT         NULL DEFAULT NULL,
  country    TEXT         NULL DEFAULT NULL,
  network    TEXT         NULL DEFAULT NULL
);

CREATE INDEX usage_arrivals_at   ON usage_arrivals (at_utc);
CREATE INDEX usage_arrivals_user ON usage_arrivals (user_id);


-- usage_visitors --------------------------------------------------------------

CREATE TABLE usage_visitors (
  day         TEXT     NOT NULL,
  visitor     TEXT     NOT NULL,
  class       TEXT     NOT NULL,
  hits        INTEGER  NOT NULL DEFAULT 0,
  has_session BOOLEAN  NOT NULL DEFAULT 0,

  PRIMARY KEY (day, visitor)
);


-- usage_people ----------------------------------------------------------------

CREATE TABLE usage_people (
  user_id     INTEGER  PRIMARY KEY,
  first_day   TEXT     NOT NULL,
  class       TEXT     NOT NULL,
  is_account  BOOLEAN  NOT NULL DEFAULT 0,
  country     TEXT         NULL DEFAULT NULL,
  network     TEXT         NULL DEFAULT NULL,
  affiliation TEXT         NULL DEFAULT NULL
);


-- usage_person_days -----------------------------------------------------------

CREATE TABLE usage_person_days (
  day        TEXT     NOT NULL,
  user_id    INTEGER  NOT NULL,
  class      TEXT     NOT NULL,
  is_account BOOLEAN  NOT NULL DEFAULT 0,
  actions    INTEGER  NOT NULL DEFAULT 0,
  analyses   INTEGER  NOT NULL DEFAULT 0,
  ui         INTEGER  NOT NULL DEFAULT 0,
  mcp        INTEGER  NOT NULL DEFAULT 0,

  PRIMARY KEY (day, user_id)
);

CREATE INDEX usage_person_days_user ON usage_person_days (user_id);


-- usage_daily_actions ---------------------------------------------------------

CREATE TABLE usage_daily_actions (
  day       TEXT     NOT NULL,
  class     TEXT     NOT NULL,
  interface TEXT     NOT NULL,
  app       TEXT         NULL DEFAULT NULL,
  kind      TEXT     NOT NULL,
  fn        TEXT         NULL DEFAULT NULL,
  area      TEXT         NULL DEFAULT NULL,
  outcome   TEXT     NOT NULL,
  n         INTEGER  NOT NULL
);

CREATE INDEX usage_daily_actions_day ON usage_daily_actions (day);


-- usage_daily_arrivals --------------------------------------------------------

CREATE TABLE usage_daily_arrivals (
  day      TEXT     NOT NULL,
  class    TEXT     NOT NULL,
  ref_host TEXT         NULL DEFAULT NULL,
  ref_path TEXT         NULL DEFAULT NULL,
  country  TEXT         NULL DEFAULT NULL,
  network  TEXT         NULL DEFAULT NULL,
  n        INTEGER  NOT NULL
);

CREATE INDEX usage_daily_arrivals_day ON usage_daily_arrivals (day);


-- usage_daily -----------------------------------------------------------------

CREATE TABLE usage_daily (
  day          TEXT     PRIMARY KEY,
  jobs         INTEGER  NOT NULL DEFAULT 0,
  wait_median  REAL         NULL DEFAULT NULL,
  wait_high    REAL         NULL DEFAULT NULL,
  waited_sec   INTEGER  NOT NULL DEFAULT 0,
  waited_long  INTEGER  NOT NULL DEFAULT 0,
  busy         INTEGER  NOT NULL DEFAULT 0,
  limited      INTEGER  NOT NULL DEFAULT 0,
  timed_out    INTEGER  NOT NULL DEFAULT 0,
  failed       INTEGER  NOT NULL DEFAULT 0,
  visitors     INTEGER  NOT NULL DEFAULT 0,
  visitor_hits INTEGER  NOT NULL DEFAULT 0,
  bots         INTEGER  NOT NULL DEFAULT 0,
  bot_hits     INTEGER  NOT NULL DEFAULT 0
);


-- usage_requests --------------------------------------------------------------

CREATE TABLE usage_requests (
  day      TEXT     NOT NULL,
  class    TEXT     NOT NULL,
  requests INTEGER  NOT NULL DEFAULT 0,

  PRIMARY KEY (day, class)
);


-- usage_hours -----------------------------------------------------------------

CREATE TABLE usage_hours (
  hour      TEXT     PRIMARY KEY,
  samples   INTEGER  NOT NULL DEFAULT 0,
  workers   INTEGER  NOT NULL DEFAULT 0,
  busy_sum  INTEGER  NOT NULL DEFAULT 0,
  busy_max  INTEGER  NOT NULL DEFAULT 0,
  queue_max INTEGER  NOT NULL DEFAULT 0,
  disk_used REAL         NULL DEFAULT NULL,
  disk_free REAL         NULL DEFAULT NULL
);
