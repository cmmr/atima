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
| 2 | Dead code and package hygiene | not started |
| 3 | Request pipeline and database layer | not started |
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

Decisions for Daniel: REST-style paths vs. keeping `/api/<verb>`; how public
projects are represented once "user 0" goes away.

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

Decisions for Daniel: hosting details for the public server; privacy/terms
text; backup policy.

## Step 10: Release

- Version, NEWS, citation, DOI.
- CRAN or r-universe submission.
- Delete this file.
