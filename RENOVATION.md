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
| 4 | Worker pool, jobs, storage, cleanup | not started |
| 5 | Auth modes, sessions, permissions | not started |
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

Decisions for Daniel: can anonymous guests upload data on the public server,
or only explore public projects; do "anyone with the link" share URLs stay,
and if so random keys only; which identity attributes are shown to other users
when sharing (name, email, ORCID iD).

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

Decisions for Daniel: hosting details for the public server; privacy/terms
text; backup policy.

## Step 10: Release

- Version, NEWS, citation, DOI.
- CRAN or r-universe submission. Remove `Remotes: cmmr/rbiom` from
  `DESCRIPTION` once rbiom 4 is on CRAN (it was 3.1.0 on 2026-11-10), and
  update the install instructions in `README.md` and the comment in the CI
  workflow.
- Delete this file.
