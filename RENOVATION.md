# atima renovation plan

Working document for bringing atima to a publishable state. Each step below is
done in its own Claude Code session, one at a time, in order. Delete this file
at release (step 10).

## How each step runs

1. Read this whole file first, then the code the step names.
2. **Ask before deciding.** Each step lists "Decisions for Daniel". Put those
   to him (with a recommendation) before writing code that depends on them. Ask
   again if something comparable comes up mid-step. Do not ask about things
   the conventions below already settle.
3. Do the work. Add or extend `testthat` tests for everything touched.
4. Before finishing: `devtools::test()` passes and `R CMD check` is no worse
   than when the step started (clean from step 2 onward).
5. Commit in small, well-described commits directly on the default branch and
   push. No feature branches.
6. Update the status table, record decisions in the "Decision log", and note
   anything the next step needs to know under that step's heading.

Stay inside the step. If you find a problem that belongs to a later step, add
it to that step's list instead of fixing it now.

## Status

| # | Step | Status |
|---|------|--------|
| 1 | Baseline and safety fixes | done (2026-11-10) |
| 2 | Dead code and package hygiene | done (2026-11-10) |
| 3 | Request pipeline and database layer | done (2026-11-10) |
| 4 | Worker pool, jobs, storage, cleanup | done (2026-11-10) |
| 5 | Auth modes, sessions, permissions | done (2026-11-11) |
| 6 | rbiom 4 schema (R side) | not started |
| 7 | Front end: schema-driven controls | not started |
| 8 | Legacy data import | not started |
| 9 | Deployment, docs, load testing | not started |
| 10 | Release | not started |

## Decision log

- **Use cases.** (a) Public multi-user server run by the lab; (b) single-user
  local installs on laptops/desktops where data must stay on the machine.
- **Server.** httpuv stays the only web server so the package is
  self-contained. The main R process does routing, auth and all SQLite access
  and never computes. rbiom work runs in a persistent `mirai` worker pool.
  A reverse proxy (TLS, rate limits) is a deployment concern, not package code.
- **Auth.** Two modes. `none`: loopback only, one implicit owner, no accounts.
  `oidc`: generic OpenID Connect (issuer URL, client id, secret), with Globus
  Auth as the documented default and ORCID supported. All password, lockout,
  reset and email-sending code is removed.
- **Front end.** No build step and no Node toolchain. Vendored libraries and
  plain ES modules. Plot controls are rendered from a JSON schema.
- **Legacy import.** Supported sources: atima 2, atima 3/4, and pre-renovation
  5.x SQLite databases. atima 1 is not supported. Import is on user request,
  from a saved copy of the old database, and may require the user's old
  credentials to decrypt their objects.
- **Git.** Commit and push straight to `main` on `origin` (`cmmr/atima`). No
  feature branches. The repository was restarted from a single commit on
  2026-11-10; earlier history lives only in the private `cmmr/atima-old` and
  must never be pushed here. Never use `git push --all` or `--tags`.
- **Example datasets (step 2).** The nine bundled BIOM files are not shipped
  in the package. Daniel chose to move them out rather than delete them:
  they are in the local, gitignored `archive/datasets/` on the dev machine
  (not in git), on hand for seeding the public server. First-run seeding
  uses rbiom's `hmp50` and `gems`.
- **rbiom and `Remotes:` (step 2).** rbiom 4 is expected on CRAN by release.
  Until then `DESCRIPTION` requires `rbiom (>= 4.0.0)` and keeps
  `Remotes: cmmr/rbiom` so installs and CI work; step 10 removes `Remotes:`.
  `ecodive` is on CRAN and atima never calls it directly, so it is not
  listed.
- **Unused worker code removed (step 2, not put to Daniel).** `run()` started
  mirai daemons and defined launchers that no request used; these and the
  `callr`, `mirai` and `promises` Imports were removed as dead code. Step 4
  adds back what its design needs.
- **API paths (step 3).** Daniel chose grouped POST actions over full REST
  and over keeping the old names: `POST /api/<area>/<action>` with a JSON
  body (multipart for uploads) and the session key in the `x-session-key`
  header. The open project stays in the server-side session. BIOM downloads
  stay `GET /<access_key>/<file>` and `GET /unsaved/<session_key>/<file>`.
- **Public projects (step 3).** Daniel chose a column on the project:
  `projects.is_public`, plus `projects.public_collection_id` for the
  project's place in the public tree. Public collections are collections
  whose `user_id` is NULL. Everyone can read a public project; it can be
  changed by users with an editor grant and by administrators
  (`users.is_admin`). `permissions` only ever holds real users.
- **Dropping `migration_*` on upgrade (step 3).** Daniel chose: back up,
  then drop. Before any schema upgrade the database is copied to
  `sqlite.db.v<N>.<UTC stamp>.bak` in the data directory; that backup of a
  5.0.x database is the "saved copy" step 8 imports from.
- **BIOM download permission (step 3).** Daniel chose: the key in the URL
  grants read (a project's access key, or the session key of an unsaved
  draft), the same rule `api_init_session()` applies to a browser. Step 5
  decides whether share links stay.
- **Publish route (step 3).** Daniel chose to add the admin-only
  `POST /api/project/publish` (sets `is_public` and the public collection
  of the open project). There is no UI for it yet.
- **Step 3 choices not put to Daniel.** (a) The router runs every handler
  inside one database transaction, so a handler that fails changes nothing.
  (b) Error responses are `{"error": {"message", "id"}}` with status 400,
  401, 403, 404, 405 or 500; the log is JSON lines on stderr, or a file via
  `options(atima.log = <path>)`. (c) rbiom's own error message is shown to
  the user when a plot fails (it names the bad option and the valid
  choices); a file that cannot be parsed gets a fixed message and the
  detail is only logged. (d) `api_export()` takes its target as arguments
  (`what`, `sample_set`, `format`, `method`, `rank`) instead of extra path
  segments. (e) The auth cookie is set with `Path=/`. (f) Password and
  lockout columns stay in `users` until step 5 removes that code.

- **Retention (step 4).** Daniel chose 24 hours and 30 days, both `run()`
  settings: a session not heard from for `session_hours = 24` is deleted
  with its unsaved draft and temporary files; a guest not seen for
  `guest_days = 30` is deleted with the projects only they could open.
  Stored files that nothing refers to go once they are 24 hours old. A
  saved project that still has a user is never deleted.
- **Worker defaults (step 4).** Daniel chose `workers` = half the cores,
  at least 1 and at most 4; `max_cpus` = cores divided by workers;
  `time_limit` = 60 seconds per job.
- **Caches (step 4).** Daniel chose both, separated. atima keeps its own
  cache for what atima derives (parsed BIOM objects, project summaries) in
  `<data_dir>/cache/atima`; rbiom's cache stays on inside workers in
  `<data_dir>/cache/rbiom`. Each gets half of `cache_size_mb`. When step 4
  was written, rbiom's cache listed its directory on every write and did
  not write atomically. Daniel changed that in rbiom (still version 4.0.0,
  not yet on CRAN) on 2026-11-11: it now writes to a temporary name and
  renames, keeps a per-process tally instead of listing on every write,
  and removes stale temporary files. He also removed the
  `rbiom.cache_hash` option, which atima stopped using in step 4 (rbiom
  keys its cache by each object's `$hash`). atima needed no change; its
  tests and `R CMD check` pass against the updated rbiom.
- **Job model (step 4).** Daniel agreed: handlers of compute routes return
  a job; the main process does "prepare" in one transaction and "finish" in
  another, with the worker in between; workers get paths and validated
  arguments and never see the database. A new request replaces the same
  session's earlier request to the same route. Stopping a job is an
  interrupt first and, if it has not stopped after 5 seconds, the end of
  that worker process and the start of a new one. Superseded and cancelled
  requests are answered 409, overdue ones 504, a full queue 503. New route
  `POST /api/session/abort` cancels a session's jobs.
- **Step 4 choices not put to Daniel.** (a) "Replaces the earlier request"
  is switched on per route (`supersede = TRUE` in the route table) and only
  for `/api/plot`, `/api/project/rarefy`, `/api/metadata/table` and
  `/api/taxonomy/table`. The plot controls ask for the values of several
  metadata fields at once and a user may start two exports, so those
  routes must not cancel each other. (b) The main process keeps its own
  job queue and only hands a job to mirai when a worker is free, so the
  time limit measures running time and not time spent waiting; at most
  `10 x workers` jobs wait. (c) The main process remembers the summaries
  of the last 50 projects it served, so opening a known project needs no
  worker. (d) If a session switches project while one of its jobs runs,
  that job's result is dropped (409). (e) `temp_dir` may not overlap
  `data_dir`; `run()` refuses to start if it does. (f) Every request that
  loads a session counts as a sign of life (it updates
  `sessions.heartbeat_utc` and the new `users.seen_utc`), not only the
  heartbeat route. (g) Cleanup runs at start-up and every ten minutes.
  (h) Schema version 3 adds `users.seen_utc`. (i) Files stored by 5.0.x
  under random names are copied to their SHA-256 names when the server
  starts. (j) PNG, JPEG and TIFF figures are drawn with `ragg` (now in
  Imports) on every platform, instead of `type = "cairo"` where R had
  cairo: macOS and container installs often lack X11 and cairo, and
  ggplot2 already picks ragg when it is installed.

- **Guests (step 5).** Daniel chose: on the public server a visitor who
  has not signed in may upload and save. The data is tied to their browser
  cookie, is deleted `guest_days` after their last visit, and becomes
  theirs when they sign in.
- **Project keys (step 5).** Daniel chose two keys per project. The
  private key (`projects.access_key`) is always there, always random (12
  lower-case letters and digits, 62 bits) and never chosen by a user;
  whoever has it can read the project, and a browser that opens it gets a
  lasting view grant. The public key (`projects.public_key`) is optional,
  short and readable; a project is public exactly when it has one, which
  replaces `projects.is_public`. Publishing and unpublishing never change
  the private key. Why 12: keys can only be guessed over HTTP, and at 62
  bits finding any one of 10,000 projects takes about 5e14 guesses, so no
  rate limit is needed for this; 8 characters (41 bits) would have relied
  on one.
- **Who may publish (step 5).** Daniel chose: any signed-in editor of a
  project, not only administrators (this replaces the step 3 choice). So
  what is in the public tree is not moderated before it appears;
  administrators can edit and unpublish public projects.
- **Identity shown to other users (step 5).** Daniel chose to keep it as
  it was: name, affiliation and a partly hidden email address, found by
  fuzzy search over all users with accounts. Someone who signs in with
  ORCID has no email to show.
- **Password accounts after the upgrade (step 5).** Daniel chose: the rows
  and their projects are kept, nobody can sign in as them, and step 8 lets
  a signed-in user claim one with the old email and password, checked
  against the pre-upgrade backup. No linking by email.
- **Old short keys (step 5).** Daniel chose: on upgrade, private projects
  whose key is shorter than 12 characters get a new random key (their old
  links stop working); keys of 12 or more stay.
- **Local owner (step 5).** Daniel chose: the one owner in `auth = "none"`
  is an ordinary user, not an administrator. They can publish their own
  projects (as any editor can) but cannot change the bundled examples.
- **Local installs have one user (step 5).** Daniel said, while the step
  ran: assume local installs (`auth = "none"`) do not need several
  accounts. So when the server starts in that mode, the owner takes over
  everything that guests and password accounts left in the database from
  before an upgrade, and those rows are deleted. Users with a provider
  identity (`issuer` set) are left alone, in case a shared server's
  database is opened in local mode by mistake.
- **Step 5 choices not put to Daniel.** (a) `run()` defaults to
  `auth = "none"`. (b) The redirect URI is `<public_url>/auth/callback`;
  `public_url` is a setting and is never taken from the `Host` header.
  (c) A sign-in lasts `signin_days = 30`, then the browser signs in again;
  there is no refresh. (d) In `auth = "none"` requests whose `Host` header
  is not a loopback name get 403, against DNS rebinding. (e) The calls to
  the provider (token, keys, userinfo) are made by the main process and
  block it for up to 10 seconds each; sign-ins are rare and this kept the
  router unchanged. (f) Administrators are named by `run(admins = )`, a
  list of provider `sub` values; when it is set, it decides `is_admin` at
  every sign-in. (g) Unfinished sign-ins (`state`, `nonce`, PKCE verifier)
  are kept in memory, not in the database, for 10 minutes; a restart
  forgets them. (h) The sharing and account routes do not exist in
  `auth = "none"`. (i) A project must keep at least one editor: the last
  one cannot be removed or demoted through sharing. (j) Guests cannot see
  who a project is shared with, search users, grant or publish. (k) A
  viewer of a public project who is not one of its members is not shown
  its private key. (l) Table cell values are HTML-escaped on the server,
  because DataTables inserts them as HTML. (m) Descriptions keep a small
  set of formatting elements and http(s)/mailto links; everything else is
  removed. (n) Sign-out does not sign the user out of the provider.
  (o) Schema version 4. (p) The `admin` permission level stays in the
  router although no route uses it now. Added after an independent
  review of the auth code: (q) a POST whose `Sec-Fetch-Site` or `Origin`
  header says it comes from another site is refused (a form elsewhere
  could otherwise make `/api/session/init` replace a visitor's cookie
  with a new guest's); (r) new route `POST /api/project/new_key`, for
  editors, gives the open project a new private key, because taking away
  a grant does not make anyone forget the old key; (s) an administrator
  cannot grant themselves a project they edit only because it is public.
  Left as decided, and worth knowing: private keys of 12 or more
  characters that a user chose under 5.0.x survive the upgrade and now
  work as share links (as they already did).

## Conventions (apply from step 2 onward)

- One concern per file; file names say what is inside (`router.R`,
  `db.R`, `jobs.R`, `auth-oidc.R`, `api-projects.R`, ...).
- Roxygen generates `NAMESPACE`. Internal functions use `@noRd`; only the
  public interface gets Rd files.
- No `:::`, no commented-out code, no functions that are never called. Old
  code lives in git history, not in the source tree.
- Validate at the boundary: every API route declares its arguments, their
  types and the permission it needs, in one place. Handlers assume valid input.
- Allow-lists use `rlang::arg_match0()` or an explicit `%in%` check. Never
  define a local helper with the same name as an imported function.
- Errors shown to the browser are a short message plus an id; details (SQL,
  parameters, call stack) go to the server log only.
- Every multi-statement database change runs inside a transaction helper.
- Anything derived from user data is escaped before it becomes HTML, on the
  server and in the browser.
- No secrets in the repository, including in examples and docker files.
  Examples use obvious placeholders.

---

## Step 1: Baseline and safety fixes

Small, uncontroversial fixes so later steps start from a safe base.

- Commit the in-progress front-end work (`inst/www/index.html`,
  `inst/www/pages/`) as a baseline commit, after checking the app still loads.
  If it is clearly broken and not quickly fixable, say so and keep it anyway.
- Remove the real SMTP credentials from `README.md` (placeholders instead).
  `docker/` is gitignored but also holds a GitHub token and SMTP credentials:
  replace them with placeholders/env references too and tell Daniel.
- `R/response.r` defines `is_string(x, null_ok)`, which shadows
  `rlang::is_string(x, string)` and silently turns every allow-list check into
  "is this a non-empty string". Remove the shadowing and make every existing
  allow-list actually enforce (plot function name in `R/plot.r`, SQL verb in
  `R/database.r`, upload component and field names in `R/files.r`,
  `R/metadata_controls.r`, `R/permissions.r`). Check the other helpers in
  `R/response.r` for the same problem.
- Default `host` to `127.0.0.1` in `run()`; fix `browseURL` for that host.
- Set up `tests/testthat/` with regression tests for the allow-lists.
- Add `RENOVATION.md` to `.Rbuildignore`.

Decisions for Daniel: none expected.

**Done. Notes for later steps:**

- Allow-lists now go through `is_one_of(x, choices)` in `R/utils.r` (a `NULL`
  or empty list matches nothing). `rlang::is_string` is still imported and is
  used only by `valid_string()`. `tests/testthat/test-allowlists.R` includes a
  general test that no local function shares a name with an import.
- Not covered by a test (verified by reading only): the `device`/`units`
  checks and the `subset_args` column-name checks inside `api_plot`, because
  they sit behind session and biom loading.
- `R CMD check` (`--no-manual`) at the end of this step: 1 error, 2 warnings,
  3 notes, none from step 1 code. Error: the example in `man/get_biom.Rd`
  calls an internal function. Warnings: stale Rd files (usage for functions
  that no longer exist; `db_init`, `resume_session`, `run` argument
  mismatches). Notes: undefined globals (the step 2 list plus `head`, `tail`,
  `hasName`, `median`, `adist`, `object.size`, `write.csv`, missing
  `importFrom`s), unused Imports, "lost braces" in `api_export.Rd`. No check
  was run before the step, so there is no before/after comparison; all of
  this is step 2 work. `devtools::test()` passes.
- Dev machine: `pandoc` and `RSQLite` had to be installed from CRAN before
  `devtools::load_all()` worked. `blastula` and `Cairo` (Suggests) are not
  installed.
- Credentials were removed from the working files, but the old values are
  still in git history (`README.md`) and in the local, gitignored `.Rhistory`.
  They stay compromised until Daniel rotates them.

## Step 2: Dead code and package hygiene

Make the package honest about what it contains.

- Delete code that is never called or cannot run: `R/garbage.r` (rewritten in
  step 4), the commented-out bulk of `R/database.r`, `api_get`,
  the old-style `p`/`k` URL branch in `R/sessions.r`, `guess_param` in
  `inst/www/js/page_plot.js`, empty/unused modals. Keep `R/migration.r` and
  `inst/www/js/migration.js` untouched as reference for step 8.
- Fix references to undefined functions (`setThreadOptions`, `md5`,
  `cli_abort`, `capture.output`, `is_scalar_logical`, `init_session`).
- `R/response.r` was copied from the `webqueue` package: trim it to what atima
  uses and rewrite its docs.
- Switch to roxygen-managed `NAMESPACE`; delete the ~100 Rd files for internal
  functions.
- Remove unused shipped files: duplicate jQuery and selectize versions,
  `inst/extdata/common_passwords.rds`, bundled datasets if nothing loads them.
- `DESCRIPTION`: require `rbiom (>= 4.0.0)`, drop unused Imports, fix
  `time_limit` default vs. documentation.
- Small confirmed bugs: `0-1` regex typo and one-byte `readBin` comparison in
  `R/files.r`; plot filenames that collide (`R/plot.r`).
- Rewrite `README.md` to match the real interface.
- GitHub Actions: `R CMD check` and tests on push.
- Found in step 1: `all_named()` in `R/response.r` is never called.
  `R/collections.r` (`AJDel6`) passes `collection_id` as the `sql` argument of
  `db_query()`, so that branch always errors. `can_grant()` calls the
  undefined `is_scalar_logical`, so `api_update_permissions` cannot succeed.
  `man/run.Rd` is stale (hand-edited `host` default only). `.Rhistory` at the
  repo root is gitignored but contains credentials; delete it locally.

Decisions for Daniel: keep or drop the nine bundled example datasets; whether
`rbiom`/`ecodive` will be on CRAN at release (affects `Remotes:`).

**Done. Both decisions are in the decision log. Notes for later steps:**

- `R CMD check --no-manual --as-cran` on Windows, R release: 0 errors,
  0 warnings, 0 notes. `devtools::test()` passes. Keep it that way.
- `NAMESPACE` is generated: imports are `@importFrom` tags in
  `R/atima-package.r`; `man/` holds `run.Rd` only. Run
  `devtools::document()` after touching roxygen comments.
- CI is `.github/workflows/R-CMD-check.yaml` (Linux release and oldrel-1,
  Windows, macOS; fails on warnings).
- Tests can build an empty database with `local_test_req()` and add rows
  with `add_test_user()` / `add_test_project()`
  (`tests/testthat/helper-db.R`). `withr` is in Suggests.
- Kept although the step listed it: `guess_param()` in
  `inst/www/js/page_plot.js` is still called from `modules/dd.js`, `irs.js`
  and `md.js`, so it is not dead (see step 7).
- Behaviour that changed: renaming a project from the tree now updates
  `projects.title` (it called the undefined `api_update_title()` for the open
  project and did nothing otherwise); figure files are named
  `plot_<random>.<ext>`; POSTs outside `/api/<name>` fail with "Not an API
  path".
- `R/migration.r` is entirely comments and `inst/www/js/migration.js` is
  untouched; both are still the step 8 reference.

## Step 3: Request pipeline and database layer

Replace "URL path becomes a function name" with an explicit design.

- **Router.** One route table: path, handler, declared arguments with types,
  required permission (`public`, `session`, `viewer`, `editor`, `admin`), and
  lane (`fast` or `compute`). Validation and permission checks happen in the
  router. Remove name-based dispatch in `R/handle_post_request.r`.
- **Database.** One long-lived SQLite connection owned by the main process.
  WAL, `busy_timeout`, `foreign_keys = ON`. A `db_transaction()` helper.
  Schema versioning with `PRAGMA user_version` and ordered migration scripts
  in `inst/sql/`; this is also the upgrade path for existing 5.x databases
  (legacy-import source "current 5.x").
- **Schema review.** Drop the `migration_*` tables and other leftovers, add
  missing indexes and `ON DELETE` rules, replace the magic rows (user 0,
  user 1000, project 10000) with something explicit.
- **Errors and logging.** Structured server log; browser gets message + id.
  Replace `error_details()`. (Step 1 note: a rejected allow-list value
  currently returns a 500 whose body is the raw `stopifnot` text; the router
  should turn these into a 400 with a short message.)
- Found in step 2 (smoke test), not fixed: every GET download such as
  `/hmp50/rare.json` returns 500. `simple_handler()` in `R/run.r` passes
  the empty request body to `webutils::parse_http()` with a `NULL` content
  type. `/api/init_session`, `/api/plot`, `/api/export/...`,
  `/api/heartbeat` and the static `/tmp` and `/www` paths were exercised
  with curl and work; a POST needs a `Content-Length`, and `/api/plot` needs
  a JSON body.
- `run()` puts the SMTP settings in `config$smtp`, but handlers read
  `REQ[['SMTP']]`, which is never set (see step 5).

Decisions for Daniel: REST-style paths vs. keeping `/api/<verb>`; how public
projects are represented once "user 0" goes away.

**Done. Decisions are in the decision log. Notes for later steps:**

- Where things are. `R/router.R`: `handle_request()` (the only entry point
  from httpuv), `route()`, the `arg_*()` argument types, `match_route()`,
  `validate_args()`, `check_permission()`. `R/routes.R`: `route_table()`,
  the one list of every route. `R/db.R`: `db_open()`, `db_migrate()`,
  `db_transaction()`, `db_query()` and friends, `db_seed()`. `R/errors.R`:
  `stop_user()` (400), `stop_unauthorized()` (401), `stop_forbidden()`
  (403), `stop_not_found()` (404), `stop_http()`, `with_user_errors()`,
  `error_response()`. `R/log.R`: `log_event()`. `R/downloads.R`: the two
  BIOM download handlers. `inst/sql/NNN_name.sql`: migrations.
- Order of work for a request: match route (404/405), load session unless
  the route is `public` (401), check permission (403), validate arguments
  (400), run the handler in a transaction. A handler is called as
  `handler(REQ, <declared args>)`; `REQ` has `DB`, `CONFIG`, `SESSION`,
  `CLIENT`, `ROUTE`, `METHOD`, `PATH`. `REQ$SESSION$access` is `"editor"`,
  `"viewer"` or `"none"` for the open project and comes from
  `project_access()` in `R/projects.r`, the single place the rule lives.
- To add a route: add a `route()` line to `route_table()` and a handler
  whose arguments are `REQ` plus exactly the declared ones. Tests in
  `tests/testthat/test-router.R` fail until the handler matches and, if it
  has required arguments, until `valid_args` in that file has an entry;
  permission and validation tests then cover it automatically.
- Raising errors: use the `stop_*()` helpers for anything the user should
  read. A plain `stop()` or `stopifnot()` becomes "Internal error" plus an
  id in the browser, with the message, SQL, parameters and call stack in
  the log under that id.
- To change the schema: add `inst/sql/003_<name>.sql` (statements end with
  `;` at end of line, comments are whole lines starting `--`). Never edit
  001 or 002. Tables with foreign keys must be rebuilt as 002 does. The
  runner turns foreign keys off, runs the script in one transaction, runs
  `PRAGMA foreign_key_check`, then sets `user_version`.
  `tests/testthat/test-db.R` checks that a 5.0.x fixture
  (`tests/testthat/fixtures/atima-5.0.sql`) upgrades to the same schema as
  a fresh install; extend its data assertions when a migration moves data.
- Schema now (version 2): `migration_*` tables, users 0 and 1000, project
  10000 and biom file 0 are gone. Every foreign key has an `ON DELETE`
  rule: cascade from users and projects to permissions, last_access,
  drafts, auth_tokens, collections; set null for `sessions.user_id`,
  `sessions.draft_id`, `sessions.auth_token_id`,
  `permissions.collection_id`, `permissions.grantor_user_id`,
  `projects.public_collection_id`; restrict from projects and drafts to
  biom_files. The default project for a new visitor is the oldest public
  project; with none, `/api/session/init` answers 404.
- Tree node ids: `C<collection_id>`, `P<permission_id>` (a project in the
  user's own tree), and new `G<project_id>` (a project in the public tree).
  `/api/tree/move` accepts `"#"` as the parent (top level) and refuses to
  move a collection into itself or a descendant.
- Old name to new path (handler function names are unchanged):

  | Old `/api/<name>` | New path |
  |---|---|
  | `init_session`, `heartbeat` | `/api/session/init`, `/api/session/heartbeat` |
  | `create_account`, `update_account`, `account_details`, `reset_password`, `sign_in`, `log_out` | `/api/account/create`, `update`, `details`, `reset_password`, `sign_in`, `sign_out` |
  | `upload_biom`, `upload_component`, `rarefy`, `save`, `save_as` | `/api/project/upload`, `upload_component`, `rarefy`, `save`, `save_as` |
  | `export/<what>/...` | `/api/project/export` with `what`, `sample_set`, `format`, `method`, `rank` |
  | (new) | `/api/project/publish` with `is_public`, `collection_id` |
  | `jstree_select`, `jstree_create`, `jstree_rename`, `jstree_leave`, `jstree_delete`, `jstree_move` | `/api/tree/select`, `create`, `rename` (argument `text`, was `jstree_text`), `leave`, `delete`, `move` |
  | `sharing_user_search`, `get_editors`, `sharing_with`, `update_permissions` | `/api/sharing/user_search`, `editors`, `list`, `update` |
  | `metadata_dt`, `metadata_thead`, `metadata_change_class`, `metadata_fields`, `metadata_levels`, `metadata_minmax` | `/api/metadata/table`, `thead`, `change_class`, `fields`, `levels`, `minmax` |
  | `taxonomy_dt`, `taxonomy_thead` | `/api/taxonomy/table`, `thead` |
  | `plot` | `/api/plot` |

- Bugs fixed on the way because they sat in code this step rewrote: GET
  downloads returned 500; the
  DataTables pager returned one row too many and failed without an `order`
  argument; `INSERT OR REPLACE` on `last_access` cleared `is_starred` on
  every request; `run()` deleted `files/` and `cache/` when it found an
  empty database.
- Verified by hand with curl against a running server (fresh data
  directory): index pages, static files, session init, heartbeat, plot,
  export, metadata table, save_as, tree create, multipart upload, all four
  download forms, and the 400/401/403/404/405 answers. Not verified: a
  real 5.0.x production database (only the fixture), and nothing was
  tested in a browser because the front end is not wired.

## Step 4: Worker pool, jobs, storage, cleanup

- Main process never computes. Compute routes go to a persistent `mirai` pool
  with rbiom preloaded. Workers receive file paths and validated arguments and
  return file paths; they never touch SQLite.
- Per-session job tracking: a new plot request cancels the previous one;
  server-enforced timeout; `cpus` pinned on every rbiom call from config.
  Remove the per-request `callr::r_bg` supervisor.
- Storage: content-addressed biom files, atomic cache writes, cache eviction
  that does not rescan the directory on every miss. Decide whether atima keeps
  its own cache or relies on rbiom's.
- Cleanup on a `later` timer: temp files, expired sessions, orphaned drafts,
  guests, unreferenced files. Covered by tests.
- Graceful shutdown (stop daemons, close DB).
- State after step 2: there is no worker code at all. Every request runs in
  the main process through `simple_handler()`. `run()` still accepts and
  type-checks `workers`, `max_cpus` and `time_limit` (default 60 s) but
  ignores them, and says so in its documentation and in `README.md`; update
  both when they take effect. `mirai`, `promises` and `callr` are no longer
  in `DESCRIPTION`. `R/garbage.r` was deleted; nothing cleans up temp files,
  sessions, drafts or guests.

- From step 3: every route has a `lane`. `compute` marks any handler that
  may read a BIOM file or call rbiom, which today includes
  `/api/session/init`, sign-in, sign-out and `/api/tree/select` because
  they end by building the `BIOM` data for the browser
  (`get_biom_data()`). The lane is recorded but not used: everything still
  runs in the main process inside `handle_request()`.
- From step 3: `handle_request()` wraps the whole handler in
  `db_transaction()`. That cannot stay as it is for `compute` routes once
  they go to workers, since a transaction must not be held open across an
  asynchronous job. Split those handlers into "prepare" (main process,
  transaction), "compute" (worker, no database) and "finish" (main
  process, transaction). `db_transaction()` nests (savepoints), so the
  pieces can call it themselves.
- From step 3: `with_rbiom_cache()` in `R/router.R` sets the rbiom cache
  options per request in the main process; workers will need the same.
- From step 3: the database connection is opened once in `run()` and
  closed by `on.exit()`. Graceful shutdown should also checkpoint the WAL.
  The old JavaScript calls `api({method: "abort"})` on page unload; there
  has never been an R handler for it, and job cancelling is this step.
- From step 3: cleanup can now rely on the foreign keys. Deleting a user
  removes their permissions, last_access rows, auth tokens and collections
  and leaves their sessions without a user; deleting a project removes its
  permissions and drafts; a BIOM file cannot be deleted while a project or
  draft points at it. Projects with no permissions and `is_public = 0` are
  the orphans left by "delete project" in the tree. `sessions` has an
  index on `heartbeat_utc`. The failed-upload and failed-plot paths can
  leave files in `data_dir/files` with no `biom_files` row, because the
  database rolls back and the file copy does not. Upgrade backups
  (`sqlite.db.v*.bak`) are never deleted.

Decisions for Daniel: retention periods (guest data, idle sessions, unsaved
drafts); default worker count and per-job CPU and time limits.

**Done. Decisions are in the decision log. Notes for later steps:**

- Where things are. `R/jobs.R`: `job()`, the pool (`pool_start()`,
  `pool_submit()`, `pool_cancel_session()`, `pool_stop()`, `pool_call()`)
  and `run_inline()`. `R/worker.R` and `R/worker-plot.R`: everything that
  runs in a worker; each `work_*()` function is one kind of job.
  `R/storage.R`: the content-addressed file store and `atomic_write()`.
  `R/cache.R`: atima's cache. `R/biom-data.R`: the browser's `BIOM`
  variable (`with_biom_data()`, `biom_reply()`, `update_draft()`).
  `R/cleanup.R`: the seven cleanup rules and the timer.
- How a compute request runs. The handler (main process, in a
  transaction) reads the database and returns
  `job(fn, args, finish)`. The router commits, submits the job and
  returns a promise to httpuv. In the worker, `worker_run()` calls
  `fn` by name. Back in the main process the router reloads the session,
  opens a new transaction and calls `finish(result)`, whose value is the
  response. A handler may also just return a response (for example when
  the answer is already known); `finish` may not return another job. A
  worker function raises `stop_user()` like a handler does; anything else
  it raises becomes a 500 whose detail and worker call stack are in the
  log.
- To add a compute route: write `work_<name>(ctx, <paths>, <args>)` in
  `R/worker.R` (first line `worker_init(ctx)`), have the handler return
  `job("work_<name>", list(ctx = worker_ctx(REQ$CONFIG), ...), finish)`,
  and declare the route with lane `"compute"`. Turn database ids into
  paths with `biom_path()` in the handler. A worker that makes a new BIOM
  file returns `store_biom()`'s `list(file, hash)`; `finish` records it
  with `register_biom_file()` or `update_draft()`. Pass `cpus =
  ctx$cpus`, or call through `with_cpus()`, on every rbiom function that
  takes `cpus`; `worker_init()` also caps the cores for rbiom functions
  that do not take it.
- `app` is now `list(db, config, pool, memo)`, and `REQ` also has `POOL`
  and `MEMO`. With `pool = NULL` jobs run in the calling process
  (`run_inline()`); most tests run that way through `test_app(REQ)`.
  Tests that need real workers use `local_test_pool()` and
  `test_app(REQ, pool)`, wait with `await()`, and can run any expression
  in a worker with `eval_job()` (helpers in `tests/testthat/helper-db.R`).
  Under `devtools::test()` the workers load atima from source; under
  `R CMD check` they load the installed package.
- Pool details worth knowing. Workers are given the main process's
  `.libPaths()` with every job, because a new R process does not know a
  library added at run time (renv, a script's `.libPaths()`); a live
  smoke test found this. Work the server does for itself goes through
  `pool_call()`, which has its own time limit (600 s) so that a short
  `time_limit` cannot stop first-run seeding. An interrupted job counts
  as stopped when its marker file is gone and the dispatcher no longer
  lists it as executing. A worker that had to be ended leaves its R
  temporary directory (and on Windows a small `Rscript<pid>` file)
  behind; the pool removes them when it stops. In tests, code run in a
  worker through `eval_job()` must not call a bare `on.exit()`: it would
  replace `worker_run()`'s own (wrap it in `local()`).
- Storage. `biom_files.file` is `<sha256>.biom` and `biom_files.hash` the
  SHA-256, for everything written from now on. Rows from 5.0.x are
  converted when the server starts (`storage_adopt_legacy()`); a row
  whose file is missing is left as it was. There is no unique index on
  `hash`; `register_biom_file()` looks before it inserts.
- Behaviour that changed for the browser: 409, 503 and 504 answers (same
  `{"error": {"message", "id"}}` body); the new `/api/session/abort`;
  `/api/project/publish` is now lane `compute` (same path and response).
  Figures are still `plot_<random>.<ext>` under `/tmp/<session_key>/`.
  Nothing else in paths or response shapes changed.
- Verified by hand against a running server installed in a scratch
  library (Windows, `workers = 1`, `time_limit = 5`): start-up and
  seeding, session init, a plot, a table page, a download, a heartbeat
  answered in about 20 ms while a slow plot ran, that plot answered 409
  when a newer one arrived, a slow plot answered 504 at 5 s, and
  `/api/session/abort`. Not verified by hand: stopping the server with
  an interrupt (the pieces are tested: `pool_stop()`, the cleanup timer,
  `db_close()`), and anything in a browser.
- Seen and not explained: in two of several whole-suite
  `devtools::test()` runs on the Windows dev machine, a job that only
  sleeps 2.5 s was stopped by a 4 s time limit, in the test that follows
  the time-limit test in `test-jobs.R`. It never happened when that file
  ran alone, under `R CMD check`, or in CI, and a traced whole-suite run
  showed correct dispatch. The test now avoids the tight margin. If
  step 9's load test shows jobs timing out early after another job was
  interrupted, look at whether a worker is handed a job before it has
  finished unwinding the interrupted one (`worker_await()` in
  `R/jobs.R`).
- Not done here, on purpose: the upgrade backups `sqlite.db.v*.bak` are
  still never deleted (step 9, backup policy); there is no per-user limit
  on queued jobs or on stored data (step 9); nothing limits how much
  memory a worker may use.

## Step 5: Auth modes, sessions, permissions

- `auth = "none"`: refuse to start on a non-loopback host; single owner.
- `auth = "oidc"`: authorization code flow with PKCE and `state`, discovery
  from the issuer URL, users keyed on `(issuer, sub)`. Session cookie is
  `HttpOnly`, `Secure`, `SameSite=Lax`, with expiry and rotation at sign-in.
- Remove passwords, lockouts, reset, `send_email`, `blastula`, `sodium`.
- Permission model written down and enforced only in the router. File
  downloads (`R/handle_get_request.r`) go through the same checks.
- Fix stored XSS: escape metadata/taxonomy names and values
  (`R/tables.r`), sanitize project descriptions on save.
- State after step 2: no email can be sent, because handlers read
  `REQ[['SMTP']]`, which is never set, so `api_create_account()` always
  creates an unverified account with the password the client supplied and
  `api_reset_password()` always answers "not enabled". `delete_account()`
  was removed as dead code (it deleted from a `resets` table that does not
  exist), so there is no way to delete an account. `blastula` is still in
  Suggests and `sodium` in Imports for this code.

- From step 3: the route table is where permissions are declared, and
  `check_permission()` in `R/router.R` enforces them. Three things are
  still checked inside handlers and should move or be written down here:
  (1) the tree routes are `session` level and check node ownership with
  `own_permission()` / `own_collection()` in `R/collections.r`;
  (2) `/api/sharing/update` is `viewer` level and applies the finer
  `can_grant()` rules; (3) the two download routes are `public` and treat
  the key in the URL as the permission (Daniel's interim choice).
- From step 3: opening a project by access key still gives the visitor a
  permanent `view` grant (`api_init_session()`), so every project is in
  effect link-shared. Public projects no longer create a grant.
- From step 3: there is no route to make someone an administrator;
  `users.is_admin` can only be set in the database. Administrators can
  publish, unpublish and edit public projects, and have no access to other
  users' private projects. `auth = "none"` needs to decide whether its one
  owner is an administrator.
- From step 3: the account routes (`/api/account/*`) are declared with
  loose string arguments and keep their own checks and `swal` responses,
  because this step replaces them. `users` still has `password`,
  `alt_password`, `n_attempts` and `locked_utc`; drop them in a new
  migration script. `R/sanity_check.r` is now only used by
  `create_collection()`, `create_access_key()`, `api_update_account()`
  and `api_init_session()` and can probably go.
- From step 3: the auth cookie is `HttpOnly`, `Path=/`, no `Secure`, and
  the log records user ids, route patterns and error details (which can
  include SQL parameters such as email addresses), never request bodies.

- From step 4: what cleanup deletes depends on `users.is_guest` and on who
  has a row in `permissions`. A guest is deleted 30 days after they were
  last seen, and a private project is deleted as soon as it has no
  permission rows. So the single owner of `auth = "none"` must not be a
  guest, and if OIDC sign-in turns a guest into a user, the guest's
  projects have to move to that user (as `api_sign_in()` does now for the
  open project only). Sessions are deleted 24 hours after their last
  request; a session cookie that outlives its session gets a 401 and the
  browser starts a new one. `users.seen_utc` (schema version 3) is
  updated by `resume_session()`.
- From step 4: sign-out (`api_log_out()`) ends by opening a new guest
  session, and the router's "reload the session after the job" step uses
  whatever session the handler left in `REQ$SESSION`, not the request's
  cookie. Keep that in mind when sessions are rotated at sign-in.
- From step 4: the download routes have no session, so their jobs cannot
  be superseded or cancelled per session, and anyone who knows a key can
  queue jobs. They share the queue limit (503 when full); a per-client
  limit belongs to the reverse proxy (step 9).

Decisions for Daniel: can anonymous guests upload data on the public server,
or only explore public projects; do "anyone with the link" share URLs stay,
and if so random keys only; which identity attributes are shown to other users
when sharing (name, email, ORCID iD).

**Done. Decisions are in the decision log. Notes for later steps:**

### The permission model

This is the model the code enforces. The rules are in `R/access.R` and are
applied by the router (`check_permission()`, `check_rule()`); handlers
check nothing. The one caller outside the router is `api_init_session()`,
which uses `open_by_key()` to choose the project a new session opens.

Who a caller is:

- **Nobody**: a request with no session (no cookie, or no session key).
- **Guest**: a browser that has not signed in. A `users` row with
  `is_guest = 1`, made the first time the page loads, forgotten
  `guest_days` after the last visit.
- **User**: someone who signed in (`is_guest = 0`), identified by
  `(issuer, sub)`. In `auth = "none"` the one owner is a user.
- **Administrator**: a user with `is_admin = 1`.

What a caller is to a project (`project_access()`):

- **Editor**: has a grant with `is_editor = 1`; or is an administrator and
  the project is public.
- **Viewer**: has a grant; or the project is public.
- **None**: otherwise. Administrators have no access to private projects
  they were not granted.

A project is public when it has a public key. Its private key works as a
share link for whoever has it: a browser that opens `/<private key>`
gets a view grant (guest or user), and `GET /<key>/<file>` serves the BIOM
file to anyone, with either key.

| May do | Nobody | Guest | User | Viewer | Editor |
|---|---|---|---|---|---|
| Load the page, start a session | yes | yes | yes | | |
| Download a BIOM file with a project key, or a draft with its session key | yes | yes | yes | | |
| Open public projects; open a project by its private key | | yes | yes | | |
| Upload a file (becomes its editor); manage own collections | | yes | yes | | |
| Plot, export, rarefy, change the working copy, save a copy | | | | yes | yes |
| See who has access, search users, share (the `grant` rule) | | no | | yes | yes |
| Save over the project, rename or delete it in the tree | | | | no | yes |
| Publish or unpublish | | no | | no | yes |

Columns "Viewer" and "Editor" are about the project open in the session;
"no" under Guest means a guest is refused even as a viewer or editor.

Sharing (`check_grant()`): editors may give, change or remove anyone's
grant, except that the last editor stays. Viewers may give view access to
people who have none, and take back a view grant they gave. Nobody is
granted view access to a public project, and nothing is granted to a
guest by name.

Tree routes (`check_nodes()`): a collection node must be the caller's; a
project node (`P<permission_id>`) must be the caller's grant, and an
editor's for rename and delete; a public node (`G<project_id>`) must be a
public project.

Route declarations in `R/routes.R` carry all of this: the level, `account
= TRUE` (signed in), `rule` (one of `tree`, `tree_edit`, `grant`,
`project_key`, `draft_key`), and `modes` (routes that exist only with
`auth = "oidc"`).

### Other notes

- Where things are. `R/access.R`: every permission rule. `R/auth.R`:
  modes, the loopback checks, auth tokens, the cookie, `sign_in()`,
  `adopt_guest()`, sign-out. `R/auth-oidc.R`: discovery, the login and
  callback pages, ID token validation. `R/html.R`: `html_escape()` and
  `sanitize_html()`. `auth_settings()` in `R/run.r` checks the settings.
  `inst/sql/004_auth.sql`: the schema change. `inst/www/js/account.js`:
  the sign-in/out control.
- Removed: `R/accounts.r`, `R/send_email.r`, `R/sanity_check.r`, the
  `smtp` argument of `run()`, `sodium` and `blastula`; `swal()` and
  `int()` (no callers left); `is_project_readable()`,
  `is_project_writable()`, `can_grant()`, `own_permission()`,
  `own_collection()`, `create_access_key()`. New Imports: `httr2`, `jose`,
  `xml2`.
- Routes that changed. Gone: `/api/account/create`, `update`,
  `reset_password`, `sign_in`. New: `GET /auth/login?return_to=<path>` and
  `GET /auth/callback` (pages, not API calls). `/api/account/sign_out`
  now answers `{"signed_out": true}` and removes the cookie; it no longer
  returns a new guest session. `/api/project/save` and `save_as` take
  `title` and `description` only. `/api/project/publish` takes
  `is_public`, `public_key` (needed the first time) and `collection_id`,
  and is for signed-in editors.
- Session data (`/api/session/init`): `CONF` is now `auth`, `user_id`,
  `full_name`, `is_guest`, `is_admin`. `BIOM` has `public_key` (or
  null), `access_key` (the private key; null unless the caller has the
  project in their own tree) and `project_key` (the one to use in URLs).
  In the public tree a node's `info.access_key` is the public key.
- Sessions. The cookie is `auth_token` (`HttpOnly`, `SameSite=Lax`,
  `Path=/`, `Secure` over HTTPS); `auth_tokens.expires_utc` is enforced
  on every request and expired tokens are removed by cleanup. The session
  key is now a number followed by 24 random characters. Sign-in and
  sign-out each replace the token and close the tabs that used the old
  one, so the page must start a new session afterwards (it gets 401
  until it does).
- Sign-in moves everything a guest has to the user (`adopt_guest()`) and
  deletes the guest. What is not carried over: unsaved changes in the
  guest's open tab, because that session is closed.
- In `auth = "none"` cleanup never deletes guests, and
  `local_owner()` folds any that exist into the owner at start-up.
- Not protected by the `Host` check in `auth = "none"`: the static paths
  `/www` and `/tmp`, which httpuv serves without calling the router.
  `/tmp/<session key>/` needs the session key.
- Tested without a real provider: `tests/testthat/helper-oidc.R` is a
  mock issuer (discovery, JWKS, token and userinfo endpoints, keys made in
  the test) behind httr2's mocking. A whole sign-in was also run by hand
  over HTTP against a mock issuer in a second R process (curl, both
  modes). **Not verified: sign-in against Globus Auth or ORCID**, and
  anything in a browser.

## Step 6: rbiom 4 schema (R side)

- One schema registry describing, per rbiom function exposed, each parameter:
  type, allowed values or range, default, label, tooltip, visibility rule.
  Served to the browser by one route and used by the router to validate
  `plot_args`.
- A test that compares the schema to `formals()` of each rbiom function and
  fails on unknown parameters; it also reports rbiom parameters not yet covered.
- Expose what rbiom 4 added: `rare_stacked`, `bdiv_corrplot`, `taxa_da`,
  `taxa_forest`, cluster functions, `write_xlsx` export, and parameters such as
  `transform`, `p.adj`, `strata`, `permutations`, `seed`, `alpha`, `weighted`,
  `unc`, `lineage`, `inflate`.
- Replace hard-coded option lists in `R/files.r` with values from rbiom.
- Remove rbiom 2/3-era argument handling in `R/plot.r`.

- From step 3: `/api/plot` declares `plot_fn` as a fixed list in
  `route_table()` (a test checks each name is exported by rbiom), but
  `plot_args`, `save_args` and `subset_args` are `arg_json()`, meaning
  "any JSON, the handler checks it". The schema should replace those with
  real validation; `arg_spec()` in `R/router.R` is the extension point for
  a new argument type. Until then a bad plot option reaches rbiom, and
  rbiom's error message is shown to the user through
  `with_user_errors()`.
- From step 3: `/api/project/export` validates `method` and `rank` only
  as short alphanumeric strings; the real lists should come from rbiom
  and the open project.

- From step 4: `plot_args` and `subset_args` are passed to the worker as
  they arrive and checked there (`work_plot()`, `subset_biom()` in
  `R/worker-plot.R`); `save_args` are checked in the main process by
  `plot_save_args()` in `R/plot.r`. Schema validation belongs in the
  main process, before the job is submitted, so a bad request never takes
  a worker. `cpus` must stay out of the schema: the worker sets it
  (`with_cpus()`), and a `cpus` sent by a browser would currently be
  overwritten for functions that take it and passed through `...` for
  those that do not.
- From step 4: the option lists `clust_options`, `dist_options` and
  `ord_options` are hard-coded in `biom_summary()` (`R/worker.R`), which
  is where "replace hard-coded option lists" now applies. New export
  formats go in `work_export()`.
- From step 4: the project summary is cached under the hashes of the two
  BIOM files only. If the summary's contents change with the schema,
  change the cache key prefix (`data_`) in `cached_summary()` and the
  in-memory copy is rebuilt on restart.

- From step 5: `route()` has more fields (`account`, `rule`, `modes`,
  `strict`, `html`); a schema route for the browser needs none of them
  (`public` or `session` level). There is a new argument type,
  `arg_html()`, that sanitizes as it validates; schema validation of
  `plot_args` should follow the same idea (the checked value is what the
  handler gets). Names and values that come out of a BIOM file (metadata
  fields, taxa, ranks) are user data: the schema's labels and choices
  built from them go to the browser as JSON text, and anything the server
  turns into HTML must go through `html_escape()` (`R/html.R`).

Decisions for Daniel: which functions/parameters are in scope for the first
release; "basic" vs. "advanced" grouping of controls.

## Step 7: Front end: schema-driven controls

- One renderer that builds controls from the step 6 schema, replacing the
  hand-written modules in `inst/www/modules/`.
- One explicit state store instead of `SYNC`/`CONF`/`BIOM` globals mutated
  from event handlers.
- Tidy the remaining pages (home, sharing, collections, modals) to the same
  conventions; finish the `pages/` split already started.
- All user-derived text inserted with text nodes or DOMPurify.
- Sign-in UI for OIDC; no account modals in `none` mode.
- State of the baseline committed in step 1: `inst/www/index.html` is a new
  static shell (Tailwind and Alpine.js loaded from CDNs, images hot-linked
  from googleusercontent.com) that fetches `/www/pages/<page>.html`. It is
  served correctly, but only `pages/home.html` exists (every other nav link
  gets a 404), it loads none of `inst/www/js/` or `modules/`, makes no `/api`
  calls, and no longer contains the `{{atima_version}}`-style placeholders
  that `R/run.r` fills in. So the UI is currently a mock-up: the old working
  UI is in git before the baseline commit, and the back end still answers
  (`/api/init_session` and `/api/plot` were exercised with curl). The CDN
  usage conflicts with "vendored libraries, no build step" and with offline
  local installs.
- Step 2 removed only the duplicate jQuery 3.6.0 and selectize 0.13.5
  (3.7.1 and 0.15.2 stay) and the empty `modals/activate_account.html`.
  Everything else under `inst/www/js/`, `modules/`, `modals/` and `assets/`
  is unreferenced by the new `index.html` but was kept as the only copy of
  the old UI code in this repository. `guess_param()` in `js/page_plot.js`
  is marked "phase out" but still has callers in `modules/`.

- From step 3: no front-end file was changed. The old code under
  `inst/www/js/` still uses the old paths and response shapes; the table
  under step 3 maps old names to new paths. What the new front end must
  expect: errors are `{"error": {"message", "id"}}` with a 4xx/5xx status
  (the old `raise_error()` in `js/api.js` expected `message`, `errcode`
  and `dumps`); 401 means "start a new session"; `CONF.migration_queue`
  is no longer sent; `BIOM.node_id` and public tree nodes use
  `G<project_id>`; `/api/project/export` takes arguments instead of a
  path; `/api/tree/rename` takes `text`; uploads are multipart forms with
  the fields named in the route table. Handler names and some response
  fields still say `jstree_`; rename them if jsTree is replaced.
  `projects.editors` and `projects.jstree_icon` are denormalised display
  columns that the new UI may not need.

- From step 4: requests to `/api/plot`, `/api/project/rarefy`,
  `/api/metadata/table` and `/api/taxonomy/table` replace the same tab's
  earlier request to that route. The replaced request is answered 409
  ("This request was replaced by a newer one."), which the front end
  should ignore rather than show. Other statuses to handle: 409 "The open
  project changed while this was running." (drop the result), 504 (the
  job passed the time limit; the message says so), 503 (queue full or
  server stopping; safe to retry). `POST /api/session/abort` (no
  arguments, answers `{"cancelled": n}`) cancels all of the tab's jobs;
  call it when the user presses stop, and with `navigator.sendBeacon` or
  `fetch(..., {keepalive: true})` on page unload. Every request keeps the
  session alive, but an idle open tab still needs the heartbeat: a
  session with no request for 24 hours is deleted and the next request
  gets 401.
- From step 4: figure and export URLs (`/tmp/<session_key>/...`) stop
  working 24 hours after the file was made, or when the session ends.

- From step 5: what exists in the front end for accounts is
  `inst/www/js/account.js` and an empty `#account-control` in
  `index.html`. It starts a session of its own to learn `CONF`, then shows
  "Sign in" (a link to `/auth/login?return_to=<path>`), or the name and
  "Sign out", or nothing when `CONF.auth` is `"none"`. Fold it into the
  state store, so the page starts one session, not two. Still to build:
  - Sign-in and sign-out are page loads. After either, start a new
    session; the old session key answers 401. Warn before signing in if
    the open tab has unsaved changes, since they are not carried over.
  - A failed sign-in shows a bare HTML page from the server (message,
    error id, link home). Style it or redirect to the app with a message.
  - In `auth = "none"`: no account menu, no sharing page (those routes
    answer 404), and the tree has no "shared by" folders.
  - Publishing: a control for signed-in editors that sends `is_public`,
    a `public_key` (4 to 20 lower-case letters, digits, inner hyphens;
    the server answers 400 with the reason if it is taken or reserved)
    and optionally a public `collection_id`. Guests are refused (403).
    Whether ordinary users should also choose the public collection, or
    only administrators, was not decided; today anyone who may publish
    may pick an existing public collection. There is still no route to
    create, rename or delete public collections.
  - Unpublishing a project that nobody has a grant on (the bundled
    examples, which have no editors and can only be unpublished by an
    administrator) makes it a private project in nobody's tree, and the
    next cleanup run deletes it. The UI should say so before it happens.
  - "New link": `POST /api/project/new_key` (editors, no arguments)
    answers `{"access_key": ...}`; every older link stops working, which
    the UI should say first. It is the only way to shut out someone whose
    grant was removed but who still has the link.
  - Requests from the app's own pages are fine as they are; a POST with
    an `Origin` or `Sec-Fetch-Site` header naming another site gets 403.
  - Share link: show `BIOM.access_key` (the private key) as the link to
    copy; it is null for someone who only sees the project because it is
    public. Use `BIOM.project_key` for download URLs in the R code shown
    next to plots: it is the public key when there is one, so a private
    key is not handed around in scripts of a public project.
  - Sharing: the user search still returns name, affiliation and a partly
    hidden email; people who signed in with ORCID have no email, so two
    people with the same name cannot be told apart there. Showing the
    ORCID iD for them was suggested and not chosen; raise it again when
    the sharing page is rebuilt. The server refuses to remove or demote a
    project's last editor (400).
  - Cell values from `/api/metadata/table` and `/api/taxonomy/table` are
    already HTML-escaped; insert them as HTML (as DataTables does), not as
    text, or they will show `&lt;`. Header HTML from the `thead` routes is
    escaped too. Descriptions are sanitized HTML and can be inserted as
    HTML; titles, names, collection names and everything else are plain
    text and must be inserted as text.
  - The old `js/` code calls routes that no longer exist
    (`/api/account/create`, `update`, `reset_password`, `sign_in`) and
    sends `access_key` to `save`/`save_as`, which now refuse it. The
    account modals under `inst/www/modals/` are dead.

Decisions for Daniel: review of the control layout once a first version runs.

## Step 8: Legacy data import

- A `legacy/` adapter per source: atima 2 (MariaDB, RSA/AES-encrypted objects
  unlocked with the user's old password; see `R/migration.r`), atima 3/4,
  pre-renovation 5.x.
- Admin points atima at a saved copy of an old database. A signed-in user
  chooses "Import from an older atima", enters their old email and password,
  atima verifies them against the old database, decrypts in memory, and copies
  the selected projects into the user's account. Old credentials are never
  stored. Re-running an import does not duplicate projects.
- Fixture databases and tests for every adapter.
- Step 2 removed the old-style share link branch from `api_init_session()`
  (it called an undefined `md5()`). For reference: a URL carried `?p=<old
  project id>&k=<base64 key>`, and the project was opened if the first 12
  characters of the MD5 of the base64-decoded `k` matched its `access_key`.
  The `migration_*` tables are still created by `init_db_structure()`, and
  the session data still sends an empty `CONF.migration_queue`, which
  `inst/www/js/migration.js` reads.

- From step 3: the `migration_*` tables no longer exist in a current
  database, and `CONF.migration_queue` is gone. A pre-renovation 5.0.x
  database upgrades in place when the server starts, so "import from
  5.x" is only needed for the unclaimed atima 2 objects those tables
  held. They survive in the automatic backup,
  `sqlite.db.v0.<UTC stamp>.bak`, which is an untouched copy of the old
  database (schema in `tests/testthat/fixtures/atima-5.0.sql`). Old ids
  are not reserved any more: imported projects get new ids.

- From step 4: an import adapter must not parse BIOM data in the main
  process. Write the old object to a temporary file and run
  `work_import()` on it through `pool_call()` or a job, then insert the
  rows with `add_project(REQ, imported)`, which is what first-run seeding
  does (`db_seed()` in `R/db.R`).

- From step 5: nothing in the package verifies passwords any more, and
  `sodium` is no longer a dependency. This step needs it back, as a
  Suggests used only by the import code:
  - Pre-renovation 5.x: `users.password` and `users.alt_password` held
    strings made by `sodium::password_store()` (scrypt); check a typed
    password with `sodium::password_verify(hash, password)`. An account
    could also have five failed attempts recorded (`n_attempts`,
    `locked_utc`); the old rule was a five-minute lockout after five
    wrong passwords, and the import should rate-limit in its own way.
    The old code is in git at `R/accounts.r` before step 5
    (`authenticate_password()`).
  - Those columns do not exist in a current database. They are in the
    backup made when the server upgraded it:
    `sqlite.db.v3.<UTC stamp>.bak` for a database that had reached schema
    3, or `sqlite.db.v0.<stamp>.bak` for one straight from 5.0.x. That
    backup is the "saved copy" to verify against.
  - After the upgrade, password accounts are still rows in `users` with
    `is_guest = 0` and no `issuer`/`sub`. Their projects, collections and
    grants are intact, other users can still share with them, and cleanup
    never deletes them, but nobody can sign in as them. "Claiming" one
    means: a signed-in user proves the old email and password against the
    backup, then everything the old row has moves to their row.
    `adopt_guest()` in `R/auth.R` does exactly that move for guests (it
    refuses a non-guest in its last statement); generalise it rather than
    writing a second one.
  - The upgrade replaced private keys shorter than 12 characters and gave
    public projects a new private key (their old address is now the
    public key). Old share links that used a replaced key are dead; the
    backup has the old keys if a redirect table is ever wanted.
  - In `auth = "none"` this is already done without a password: at
    start-up the local owner takes over everything that guests and
    password accounts had (`local_owner()` in `R/auth.R`), so a local
    install upgraded from 5.0.x needs no claiming. Claiming is only for
    the shared server.
  - Importing shared-project permissions needs users to exist; with OIDC
    a user only exists once they have signed in.

Decisions for Daniel: how old MariaDB data is supplied (offline conversion to
SQLite vs. live connection); whether shared-project permissions are imported
or only ownership. **Needed from Daniel before this step:** a database
snapshot (or a small synthetic one with the real schema) for each source
version, plus a test account for each.

## Step 9: Deployment, docs, load testing

- Docker image and a compose file with Caddy for TLS; configuration only via
  environment variables; no secrets in files.
- Step 1 changed the local (gitignored) `docker/` files: `atima5.dockerfile`
  now reads the GitHub token from a BuildKit secret
  (`docker build --secret id=github_pat,src=<file> ...`) and `compose.yaml`
  takes `ATIMA_SMTP_USERNAME`/`ATIMA_SMTP_PASSWORD` from the environment or
  an `.env` file. Neither was rebuilt or run after the change.
- Load test with concurrent simulated users; record results for the paper.
- Vignettes: local install, server deployment, OIDC setup, legacy import,
  data-handling notes for local use.
- pkgdown site.
- From step 2: `vignettes/articles/nginx.Rmd` is stale (it calls
  `run(config = list(...))`, which does not exist) and `vignettes/` is in
  `.Rbuildignore`. `DESCRIPTION` lists `https://cmmr.github.io/atima/` as a
  URL although no site is published. The nine example BIOM files for
  seeding a public server are in the local `archive/datasets/`, not in git.
  `todo.txt` and `logo.pptx` at the repo root are tracked but not part of
  the package.

- From step 3: the server log is JSON lines on stderr (one `request` line
  per request, one `error` line per failure, with a shared error `id`),
  so a container can collect it as is; `options(atima.log = <path>)`
  writes to a file instead and there is no rotation. The database runs in
  WAL mode: back up with `VACUUM INTO` or the SQLite backup API, not by
  copying `sqlite.db` alone. Schema upgrades write
  `sqlite.db.v<N>.<stamp>.bak` next to the database and never remove it.
  A reverse proxy should pass `/api/`, `/www/`, `/tmp/` and the root-level
  project paths; access keys `api`, `www`, `tmp` and `unsaved` are
  reserved.

- From step 4: sizing. Memory is roughly one R process with rbiom loaded
  per worker, plus the main process. `workers` x `max_cpus` should not
  exceed the cores the container may use; inside a container
  `parallelly::availableCores()` respects cgroup limits, so the defaults
  follow the container's CPU quota. Requests wait in a queue of at most
  `10 x workers`, then get 503. With one worker, a table page or a
  project nobody has opened since the restart waits behind a running
  plot (up to `time_limit`); the load test should measure that. There is
  no per-user fairness in the queue.
- From step 4: new log events: `pool_start`, `pool_stop`, `job_timeout`,
  `worker_killed`, `worker_lost`, `worker_replace_failed`, `cleanup`
  (counts per rule, only when something was removed), `cleanup_failed`,
  `storage_adopt_legacy`. Worker processes write nothing to the log
  themselves.
- From step 4: `temp_dir` must be outside `data_dir` and is emptied of
  old files by the server, so give it its own volume or directory.
  `<data_dir>/cache` can be deleted at any time. Stopping the server
  (SIGINT, or SIGTERM if R turns it into an interrupt; check this in the
  container) cancels jobs, stops workers and checkpoints the database.
  Whether `docker stop` gives a clean shutdown was not tested.
- From step 4: not verified on Linux or macOS by hand, only by CI: ending
  a stuck worker (`tools::pskill()`), and replacing one.

- From step 5: **what Daniel has to register before the public server can
  sign anyone in.** One provider per server; Globus Auth is the default.
  - Globus Auth: sign in at `https://app.globus.org/settings/developers`,
    choose to register a portal or web application you host (not a
    native app, not a service account), in a project of the lab's. Set
    the redirect URL to exactly `https://<the server's host>/auth/callback`
    (Globus only accepts HTTPS, except `http://localhost`, which is handy
    for a trial run on a laptop: `http://localhost:8080/auth/callback`).
    Scopes: `openid`, `profile`, `email`. Then generate a client secret.
    Give the server `ATIMA_AUTH=oidc`, `ATIMA_PUBLIC_URL=https://<host>`,
    `ATIMA_OIDC_CLIENT_ID` and `ATIMA_OIDC_CLIENT_SECRET`; the issuer
    default, `https://auth.globus.org`, is right. Globus signs ID tokens
    with RS512 and wants the secret by HTTP Basic; both are handled.
  - ORCID instead: sign in at `https://orcid.org`, open Developer Tools
    under your name, register for the public API, and add the same
    redirect URI (HTTPS only in production, and it must match exactly,
    host included). Set `ATIMA_OIDC_ISSUER=https://orcid.org` plus the
    client id and secret. ORCID knows only the `openid` scope and sends
    no email, so its users show a name only. ORCID has a sandbox
    (`https://sandbox.orcid.org`) for trying it first.
  - To make someone an administrator, sign in once, read the `sub` from
    `users.sub` in the database, and set `ATIMA_ADMINS` to a
    comma-separated list of those values. For Globus the `sub` is a
    UUID; for ORCID it is the ORCID iD.
  - The client secret belongs in the container's environment or a secret
    store, never in a compose file in git. It is not logged and is not
    passed to worker processes.
- From step 5: the reverse proxy must terminate TLS and pass `/auth/`
  as well as the paths listed above. Either set `public_url` to the
  `https://` address (enough for the cookie's `Secure` flag) or have the
  proxy set a header such as `X-Forwarded-Proto` and name it in
  `ATIMA_FORWARDED_PROTO_HEADER`; the proxy must then overwrite that
  header on every request, so that a client cannot send its own. `host`
  must be `0.0.0.0` (or the container's address) and `auth` must be
  `oidc`: with `auth = "none"` the server refuses to start on such a host
  and refuses requests whose `Host` header is not a loopback name, so a
  proxied local install does not work by design.
- From step 5: still for the proxy to do: rate-limit `/api/session/init`
  (every cookie-less call makes a guest row, removed after `guest_days`),
  `/auth/login` (at most 5,000 unfinished sign-ins are kept; more get
  503) and the key-in-URL routes. Sessions record `REMOTE_ADDR`, which
  behind a proxy is the proxy's address; nothing uses it.
- From step 5: sign-in calls the provider from the main R process
  (token endpoint, keys, sometimes userinfo), each with a 10 second
  timeout, and the server answers nothing else meanwhile. Include
  sign-in under a slow provider in the load test; if it matters, make
  those calls with `httr2::req_perform_promise()`. The provider's
  discovery document is read at start-up; if that fails the server
  starts anyway, logs `oidc_discovery_failed`, and tries again at the
  first sign-in. New log events: `sign_in`, `sign_out`,
  `oidc_discovery_failed`; a refused sign-in is an `error` event whose
  `detail` says which check failed.
- From step 5: docs to write (OIDC setup vignette): the two provider
  recipes above; that changing `oidc_issuer` on a server with users makes
  them all strangers, because users are `(issuer, sub)`; that moving a
  data directory from `auth = "none"` to `oidc` leaves the local owner's
  projects with a user nobody can sign in as; and, for local use, that
  anyone with access to the computer while the server runs can open the
  app. Public content is unmoderated (any signed-in editor can publish),
  which the terms text should cover.

Decisions for Daniel: hosting details for the public server; privacy/terms
text; backup policy.

## Step 10: Release

- Version, NEWS, citation, DOI.
- CRAN or r-universe submission. Remove `Remotes: cmmr/rbiom` from
  `DESCRIPTION` once rbiom 4 is on CRAN (it was 3.1.0 on 2026-11-10), and
  update the install instructions in `README.md` and the comment in the CI
  workflow.
- Delete this file.
