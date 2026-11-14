# atima renovation plan

Working document for bringing atima to a publishable state. Each step below is
done in its own Claude Code session, one at a time, in order. Delete this file
at release (step 14).

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
| 6 | rbiom 4 schema (R side) | done (2026-11-12) |
| 7 | Front end: schema-driven controls | done (2026-11-12) |
| 8 | Legacy data import | done (2026-11-12) |
| 9 | MCP server, local | done (2026-11-13) |
| 10 | Deployment, docs, load testing | done (2026-11-14) |
| 11 | MCP server, shared (sign-in), and tools that change data | not started |
| 12 | Usage monitoring | not started |
| 13 | Interface refinement: compact controls, navigation | not started |
| 14 | Release | not started |

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
  `Remotes: cmmr/rbiom` so installs and CI work; step 14 removes `Remotes:`.
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
- **MCP server (2026-11-11, after step 5).** Daniel chose to add an MCP
  (Model Context Protocol) server, so that AI apps can explore projects
  and make figures for a user. Published API documentation alone was
  considered and is not enough: chat apps can only call tools they are
  given, and the browser API needs a tab session, a cookie and a sign-in
  by page redirect. The agent path is added beside the browser path,
  without reworking steps 4 and 5 first: an agent is the local owner or
  the user of a bearer token, names the project in each call, and runs
  jobs with no tab session and no supersede. Steps were added and
  renumbered: 9 is the MCP server for `auth = "none"`, 10 deployment (was
  9), 11 MCP sign-in for shared servers, 12 release (was 10). Step 6
  builds its schema so it can also serve as tool definitions, and step 10
  adds per-account job limits.
- **rbiom describes its own functions (step 6).** Daniel chose, when the
  step found that rbiom's option lists and limits were only literals
  inside its function bodies: pause the step and add the description to
  rbiom. rbiom 4.0.0 (commit c83cf32) now exports `fn_schema()` (every
  parameter's type, choices, limits, default, when it has any effect, a
  one-line description), `fn_check()` (checks a list of arguments against
  that and a small description of a dataset, without running anything),
  `fn_check_data()` and `list_palettes()`. atima repeats none of rbiom's
  lists. It adds which functions are exposed, labels, the basic/advanced
  group, the image settings and sample filter, and the route.
- **Functions in scope (step 6).** Daniel chose all 14 plot functions
  rbiom describes: the 10 exposed before plus `bdiv_corrplot`,
  `rare_stacked`, `rare_corrplot` and `taxa_forest`. `taxa_da()` is not a
  figure; its table is `taxa_forest`'s statistics table.
- **Parameters in scope (step 6).** Daniel chose: everything rbiom lets a
  remote caller set, which is all but the ones it marks R-only (`biom`,
  `tree`, `cpus`, `file`, `clone`, `overwrite`, `...`) or deprecated
  (`weighted`, `normalized`). A new rbiom parameter appears without a
  change to atima, under its own name until someone gives it a label; a
  test reports those. `schema_hidden` in `R/schema.R` is where to hide one.
- **Clusters (step 6).** Daniel chose: `taxa_clusters` and `bdiv_clusters`
  add their result to the working copy's metadata as a categorical field
  (new route `POST /api/metadata/add_clusters`), so any plot can color,
  facet or test by it.
- **Basic and advanced (step 6).** Daniel chose one rule by parameter
  name, the same in every function: basic is what chooses what a figure
  shows (`x`, the metric, `ord`, `rank`, `taxa`, `layers`, `stat.by`,
  `facet.by`, `colors`, `shapes`, `patterns`, `test`, `tracks`, `regr`,
  `label.by`, `order.by`, `rline`, `k`); everything else is advanced.
- **Schema shape (step 6).** Daniel chose one static schema, the same for
  every project, from one route. Parameters whose choices depend on the
  data carry a type (`field`, `rank`, `taxa`, `metric`) and the browser
  fills them in from the project summary it already has.
- **Counts that are not whole numbers (step 6).** Daniel chose: the user
  is asked at upload. Such a file is refused with the error code
  `confirm_inflate` and a message that warns what scaling does; sent
  again with `inflate = true` it is scaled once, at import
  (`rbiom::biom_inflate()`), and is an ordinary project from then on.
  Before this such an upload failed with an internal error.
- **rbiom says which counts and which packages (step 6).** After the
  step, Daniel had rbiom add to its schema which counts each function
  wants (`counts`), which choices need a package rbiom only suggests
  (`choices_needs`), and that the Excel export needs one (`needs`).
  atima follows them: `taxa_forest` is now drawn from the counts before
  rarefying, as rbiom recommends for LinDA; a choice or parameter whose
  package the server lacks is not offered and is refused if asked for.
  Daniel also decided in rbiom: its version stays 4.0.0 until that is on
  CRAN, so atima tells schemas apart by a hash, not the version; and a
  metric that gives infinite or missing distances stops with a clear
  message instead of being removed from the choices.
- **Step 6 choices not put to Daniel.** (a) When the main process does
  not have the project's summary in memory (only just after a restart),
  the checks that need the project are made by the worker, first thing,
  with the same functions and the same messages; the checks that need no
  project (unknown parameter, `cpus`, image settings) are always made in
  the main process. (b) The main process now calls three rbiom functions,
  `fn_schema()`, `fn_check()` and `list_palettes()`. They read a
  description, never a BIOM file; a check takes about 2 ms. (c) The
  project summary was reshaped (see the step 6 notes) and its lists of
  metrics and methods were removed, since the schema has them. (d) A
  failed check is reported as "Argument 'plot_args' is not valid."
  followed by rbiom's own message. (e) Image settings: `tex` and `wmf`
  are no longer offered (`wmf` only works on Windows); the default
  resolution went from 300 to 100 dpi, because the default 400 x 300
  pixels at 300 dpi is too small to hold an ordination; each side must be
  50 to 12,000 pixels; an image too small for its figure is a 400 with a
  message, not a 500. (f) Error bodies may carry `error.code`, used only
  for `confirm_inflate`. (g) Cluster labels are "Cluster 1", "Cluster 2",
  ..., not rbiom's "1", "2", so that the field is still categorical after
  the project is saved and read again; samples that rarefying dropped
  have no cluster. (h) The Excel export is `what = "xlsx"`, written by
  `rbiom::write_xlsx()` at the depth on screen; `openxlsx` is in Suggests.
  (i) What is not checked before a worker runs, because rbiom checks it
  only against computed data: taxa names, the names in a `colors`,
  `shapes` or `patterns` mapping, color and palette names inside a
  vector, the inside of a `tracks` or `grid` list. Those get a shape and
  size check, and rbiom's message if they are wrong.

- **Front-end stack (step 7).** Daniel chose no framework: plain ES
  modules, a small helper for building elements, and one hand-written
  style sheet that keeps the mock-up's look. Alpine and Tailwind (which
  would need a compiler run for every class change) and the old jQuery
  widgets (selectize, jsTree, DataTables, ion-rangeSlider, sweetalert,
  simditor, lodash) are gone. Only highlight.js, DOMPurify and Font
  Awesome remain, all of which were already in the repository. The cost,
  accepted: the picker, tables, tree and dialogs are atima's own code.
- **Plot page layout (step 7).** Daniel chose: navigation on the left, the
  figure with Statistics and R code as tabs in the middle, and the
  controls on the right, with Basic open and Advanced, Samples (the
  sample filter, shared by all plots) and Image as sections that open.
  He reviewed the first running version and found the layout fine.
- **ORCID iD in the sharing search (step 7).** Daniel chose to show it for
  people who signed in with ORCID. It is public by design and, since ORCID
  sends no email, the only thing that tells two people of one name apart.
  What any other provider calls a person still never leaves the server.
- **Who picks the public collection (step 7).** Daniel chose: anyone who
  may publish, as the server already allowed. Public collections can
  still only be made in the database.
- **The old public site (step 7).** Daniel said the site at
  atima.research.bcm.edu is a very old version and the new interface need
  not match it.
- **Step 7 choices not put to Daniel.** (a) The address is
  `/<project key>#/<page>/<argument>`, e.g. `/hmp50#/plot/adiv_boxplot`:
  the path names the open project (by the key that is safe to show) and
  the part after `#` the page. (b) A figure is drawn 0.4 s after the last
  change, fitted to the window at the screen's pixel ratio unless "Fit the
  figure to the window" is switched off, and always comes with its
  statistics and code (`attrs = true`). (c) A file dropped anywhere on the
  page is uploaded. (d) The page is sent with a Content-Security-Policy
  that allows this server only, with no inline script or style, and
  static files with `Cache-Control: no-cache`. (e) Responses say `tree`
  and `tree_node` (were `jstree_data`, `jstree_node`), the handlers are
  `api_tree_*()`, and `/api/sharing/list` answers `users` (objects), not
  `dt_data`. (f) `/api/metadata/fields`, `levels` and `minmax` were
  removed. (g) The two page routes ignore query parameters they do not
  know. (h) Publishing is offered to the local owner too (`auth =
  "none"`), since the server allows it. (i) First-version limits of the
  controls: a `rank` parameter takes one rank, and heat-map parameters
  that accept separate values for rows and columns (`per_side`) take one
  value; palettes for heat maps can be chosen and reversed but not
  entered by hand. (j) Schema version 5 repairs creation dates (see the
  step 7 notes).

- **Legacy import: atima 2 only (step 8).** Daniel said only the database
  of the live site at atima.research.bcm.edu needs importing. That is
  atima 2 (Shiny, MariaDB, bcrypt passwords, every object encrypted). He
  chose to drop the atima 3/4 and pre-renovation 5.x SQLite import, and
  the claiming of an upgraded 5.x password account that step 5 had left
  for this step: no other server ever held real accounts. This replaces
  the list of sources in the "Legacy import" entry above and the
  "Password accounts after the upgrade (step 5)" plan: password rows in
  an upgraded 5.x database stay as they are and cannot be claimed.
  (Found on the way: the code in `archive/atima3.zip` is 4.0.0.9038 and
  stores data like 5.0.x; and the `migration_*` tables of 4.x and 5.0.x
  were only ever filled by code that was commented out.)
- **How the old data is supplied (step 8).** Daniel chose a one-time
  conversion to SQLite: the administrator runs the exported
  `legacy_convert(<DBI connection>, <file>)` against the old MariaDB,
  and starts the server with `run(legacy = c(<label> = <file>))` or
  `ATIMA_LEGACY`. The running server needs no MariaDB, no driver and no
  database password, and only reads the file.
- **Sharing on import (step 8).** Daniel chose: rebuilt as people
  import. A project is imported once; someone else who could open the
  old project and imports it later is added to that same project with
  their old level, instead of getting a copy.
- **Wrong old passwords (step 8).** Daniel chose: five per 15 minutes,
  for the signed-in person and separately for the old account, counted
  in the database so that a restart does not reset them, with the old
  email address kept only as a hash.
- **Import design (step 8).** Daniel agreed: bcrypt, RSA, AES and all
  reading of the old database happen in a worker, in memory; the
  metadata, taxonomy and tree that atima 2 kept beside the uploaded BIOM
  file (and let users edit) are laid over the file, as the old migration
  code did.
- **Imports run in the background (step 8, 2026-11-13).** Daniel asked
  for this once the real data showed how long imports take: "Import
  selected" is one request that hands the server the list and returns;
  the server imports one project at a time per person and the person
  keeps using the site. This replaces "one request per project". Its
  cost, accepted: the old password stays in the main process's memory
  (never on disk) for as long as that person's import runs, and a
  restart ends running imports.
- **Step 8 choices not put to Daniel.** (a) The first importer gets the
  level they had, not editor: a viewer who imports first has a project
  with no editor until an old editor imports it (the question put to
  Daniel said "becomes its editor"; this is the stricter reading, so
  that importing never gives anyone more than they had). (b) The public
  example projects of the old site are not offered: the converter drops
  the view grants that every account had on them. (c) The converter
  leaves out names, affiliations, sessions, tokens and cached results;
  the new account's name comes from the identity provider. (d) An
  imported project keeps its old creation date and the rarefaction
  depth it was set to. (e) The import routes exist in both auth modes
  (the local owner is a user), and the page is linked only when a
  legacy file is registered. (f) An attempt is counted before the
  password is checked and taken back when it proves right, so a check
  that times out or whose worker dies counts as a wrong attempt. Only
  "find my projects" and "start" are counted; the projects of a started
  import are not, since its password has been checked.
  (g) `bcrypt` and `RMariaDB` are Suggests; `sodium` did not need to
  come back, because nothing verifies a scrypt hash now. (h) Schema
  version 6. (i) atima 2's user key came out of a base64 decoding of
  text that is not base64, so it depended on the old server's OpenSSL;
  the adapter tries each key a plausible decoder would have given and
  lets AES-GCM's authentication choose (see the step 8 notes).
  Decided after the real data was tried (2026-11-13): (j) atima 2's
  stored MD5 of each object is not checked, because it is wrong for
  objects that decrypt and read correctly; AES-GCM already refuses
  anything altered. (k) A sample that atima 2's metadata table has no
  row for is kept, with empty metadata, as atima 2 showed it; laying
  the table over the file as it is would have dropped such samples
  (10 to 106 of them in three of the first twelve real projects).
  (l) One project of a background import may run for 15 minutes
  (`legacy_time_limit`), not the 60 seconds a request gets. (m) Each
  person has one import at a time, kept until they start another.

- **MCP protocol revision (step 9).** The specification had moved on
  since the plan was written. The current revision, 2026-07-28, is
  stateless: there is no `initialize` handshake, no
  `notifications/initialized`, no `ping` and no session; every request
  carries its protocol version and the client's capabilities in
  `params._meta` and repeats the version, method and tool name in
  headers; `server/discover` is mandatory. Daniel chose to serve the
  current revision only, over also answering the 2025 handshake
  ("dual-era", which the specification allows) and over building the
  plan's handshake. An app that opens with `initialize` is refused with
  an error that names 2026-07-28. Claude Code 2.1.325 speaks the current
  revision and connects.
- **MCP tools (step 9).** Daniel chose six tools: the plan's five
  (`list_projects`, `describe_project`, `run_stats`, `make_plot`,
  `export`) plus `describe_function`. `run_stats` and `make_plot` take
  the name of an rbiom function and an `args` object; the function's
  argument schema is fetched on demand with `describe_function`, so the
  tool list is about 10 kB. One tool per rbiom function (about 23 tools,
  about 80 kB of definitions in every conversation) and five tools with
  no way to ask for a schema were the alternatives.
- **Rows in a result (step 9).** Daniel chose 50 rows of a statistics
  table by default, the caller may ask for up to 500 (`max_rows`), the
  rows come as rbiom sorts them (smallest p-value first), and the whole
  table is always written to a CSV file whose address is in the result,
  with a note that says rows were left out and how to narrow the request.
- **Tools that change data (step 9).** Daniel chose to leave room for
  them: no tool changes data now, but each tool declares the permission
  it needs and whether it only reads, and a tool that writes is offered
  only when the configuration says so (`mcp_writes`, which `run()` sets
  to `FALSE` and has no argument for yet). Adding upload or save later is
  a line in the tool table, a handler, and that switch.
  On 2026-11-14 Daniel asked for those tools (upload, save, share,
  publish, delete) to be built in step 11; that step's section says how.
- **Step 9 choices not put to Daniel.** (a) A tool call that names a
  project needs a grant on it, or the project must be public. Knowing a
  private key is not enough and never creates a grant (in the browser it
  does both), and a key the caller may not use gets the same answer as a
  key that does not exist. This settles for step 9 the question step 11
  lists; with one local owner it only shuts out projects of users who
  came from a shared server's database. (b) Error mapping: unreadable
  JSON, a missing field, mismatched headers, an unknown method (HTTP
  404) or tool are JSON-RPC errors with an HTTP error status; from a
  known tool on, every error written for the user (400, 403, 404, 409,
  503, 504) is a result with `isError: true` and HTTP 200; anything else
  is JSON-RPC -32603 with HTTP 500 and the error id. (c) Results carry
  their data twice, as the specification recommends: `structuredContent`
  and the same JSON as text. No tool declares an `outputSchema`.
  (d) Figures are PNG, 900 x 600 pixels at 100 dpi unless the call says
  otherwise, 200 to 2000 pixels a side; other formats are for the
  browser. Numbers in a result's table are rounded to four significant
  digits (the CSV file has them in full). (e) `describe_project` lists at
  most 50 values per categorical field, the 10 most abundant taxa per
  rank and 40 depths; `list_projects` at most 200 projects. (f) Each
  call's files go into a directory of their own with a random 24
  character name under `<temp_dir>/mcp/`, served at `/tmp/mcp/...`; the
  name is the only protection, as a session key is for a tab's files.
  (g) `export` offers `biom`, `xlsx`, `metadata`, `taxonomy`, `tree`,
  `alpha`, `beta` and `taxa`, not the file as uploaded. (h) `mcp` and
  `oauth` are reserved project keys. (i) `GET /mcp` answers 405 without
  accounts; with accounts the POST route does not exist (404) and a GET
  is, like any word after the slash, a request for the app's page.
  (j) Requests are logged with their method and tool name (`rpc`), never
  with their arguments. (k) The tool list and the discovery answer say
  they may be cached for five minutes, by anyone (`cacheScope:
  "public"`). (l) `jsonvalidate` (and with it V8) is a Suggests, used
  only by tests, which skip without it.
- **Usage monitoring (added 2026-11-13).** Daniel asked for an
  administrators' page that quantifies atima's use among researchers
  (active users over time, where they come from, browser against MCP,
  which analyses) and shows when the server is outgrown. It is step 12,
  and release moved to step 13. His reason: in academia a tool that many
  people use is what earns grant money, so the numbers must measure
  reach and repeat use, not the usual profit-focused statistics.
- **Interface refinement (added 2026-11-14).** Daniel finds the plot
  controls of the new front end too tall: a label above every control,
  like the R Shiny interface of atima 2, which he does not like. He
  wants them compact, as in the plot controls he designed for the
  pre-renovation 5.0 (the version in `cmmr/atima-old`, which he calls
  atima 4), with an unopened dropdown and its label on one line, and usable on a
  wide range of screen sizes. Two navigation links are much longer than
  the rest and are to be renamed. It is step 13, after the steps that
  still add pages; release moved to step 14.

- **Hosting (step 10).** Daniel has not decided where the public server
  runs, so nothing in the repository names a host. The deployment files
  serve both arrangements by setting: Caddy facing the internet with a
  Let's Encrypt certificate, or Caddy on plain HTTP behind an
  institution's own proxy (`ATIMA_SITE_ADDRESS=:80` and
  `ATIMA_TRUSTED_PROXIES`). The sign-in provider is Globus Auth.
- **Deployment files (step 10).** Daniel chose `deploy/` at the root of
  the repository, outside the built package; the load test is beside it
  in `loadtest/`. The old local `docker/` stays untracked and unused.
- **Backups (step 10).** Daniel chose nightly, the newest 7 kept plus the
  newest of each of the last 4 weeks, made by a `backup` service in the
  compose stack: the database through SQLite's backup API, each stored
  file once. The upgrade copies `sqlite.db.v<N>.*.bak` are pruned to the
  newest 3 by the same service.
- **Privacy and terms (step 10).** Daniel chose fixed text shipped in the
  package, drafted in this step and still to be reviewed by him, shown as
  a page of the app on shared servers only. Because other labs will run
  the same text, it names nobody: `run(operator = , contact = )` say who
  runs a server.
- **Per-account job limit (step 10).** Daniel chose 16 jobs waiting or
  running per account (guests included), `run(jobs_per_user = 16)`. A
  server without accounts has one user and keeps only the queue limit.
- **Public collections (step 10).** Daniel chose routes for
  administrators and controls in the project tree, over a documented SQL
  recipe.
- **Clutter (step 10).** Daniel said to remove `todo.txt`, `logo.pptx`
  and whatever else is not needed; the unused pictures
  `inst/www/img/gallery/` and `AdrienSaraLogo.png` went too.
- **GitHub Pages (step 10).** Daniel had the session switch Pages on for
  `cmmr/atima`, with GitHub Actions as its source: the site is published
  as a Pages artifact and no `gh-pages` branch exists.
- **Step 10 choices not put to Daniel.** (a) The public collection routes
  are separate, admin-level routes (`/api/public/*`) with their own rule,
  not an extension of `/api/tree/*`; a public collection that still holds
  something cannot be deleted, as for a user's own. Administrators can
  also move public projects between collections. (b) `GET /api/health`
  is the one API route that is a GET. (c) Sign-in asks the provider in
  the background (this replaces step 5's choice (e)): the load test was
  to decide, and a provider that takes two seconds would have stopped the
  server for two seconds per sign-in. Only the fetch of the provider's
  signing keys still blocks, when they are unknown or have changed.
  (d) Responses to requests that used a worker carry a `Server-Timing`
  header with the time the job waited and ran; the load test reads it.
  (e) A background legacy import counts as one of its person's jobs, and
  waits out a 429 as it does a full queue. (f) The image stops cleanly on
  SIGTERM as well as SIGINT: `dumb-init` turns the first into the second
  for R. (g) Caddy writes no access log, because request paths contain
  private project keys. (h) Rate limits per address and minute: 120
  session starts, 30 sign-in requests, 10 old-password checks, 60
  key-in-URL downloads, 30 OAuth requests, 1,200 API calls; all settings.
  `/mcp` has no limit by address. (i) `restore` refuses while
  `sqlite.db-wal` exists, which is how a running server shows; `force`
  overrides it after a crash. (j) `httr2 (>= 1.3.0)`. (k) The articles
  are pkgdown articles under `vignettes/articles/`, not package
  vignettes, so the package gains no dependency.

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
  step 10's load test shows jobs timing out early after another job was
  interrupted, look at whether a worker is handed a job before it has
  finished unwinding the interrupted one (`worker_await()` in
  `R/jobs.R`).
- Not done here, on purpose: the upgrade backups `sqlite.db.v*.bak` are
  still never deleted (step 10, backup policy); there is no per-user limit
  on queued jobs or on stored data (step 10); nothing limits how much
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
  limit belongs to the reverse proxy (step 10).

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

- From the MCP decision (2026-11-11, see the decision log): step 9 serves
  this schema to AI apps as tool definitions, so build it with that in
  mind.
  - Write validation as a function of the rbiom function, its arguments
    and the project's summary, not one that reads `REQ$SESSION`. Step 9's
    `/mcp` route names the project in each call and has no tab session.
    The same goes for choice lists built from metadata (fields, levels,
    ranks).
  - Make the registry able to output JSON Schema for each function:
    types, enums, minimum and maximum, defaults, with the label and
    tooltip as the `description`. A model reads the tooltips when it
    chooses arguments, so they should say what a parameter does, not
    only name the control.
  - Cover rbiom's `adiv_stats()`, `bdiv_stats()` and `taxa_stats()` as
    well, even if the browser does not call them: step 9's stats-only
    tool screens many metadata fields without drawing a figure.

Decisions for Daniel: which functions/parameters are in scope for the first
release; "basic" vs. "advanced" grouping of controls.

**Done. Decisions are in the decision log. Notes for later steps:**

- Where things are. `R/schema.R`: the exposed functions
  (`schema_functions`), labels (`schema_labels`), the basic list
  (`schema_basic`), `schema_params(fn)`, the checks (`check_fn_args()`,
  `check_save_args()`, `check_subset_args()`), the browser's schema
  (`browser_schema_json()`, `api_schema()`) and JSON Schema
  (`fn_json_schema()`). `R/router.R`: the argument types `arg_fn_args()`,
  `arg_save_args()`, `arg_subset_args()`, `arg_rank()`, `arg_metric()`.
  `tests/testthat/test-schema.R`: all of it, including one real plot per
  function.
- To expose another rbiom function: it must be in `rbiom::fn_schema()`;
  add a line to `schema_functions` and a route (or reuse `/api/plot` with
  `use = "plot"`). To label a parameter: `schema_labels`. Tests fail if
  either table names something rbiom does not have.
- How an argument check can use the project. An argument type declared
  with `context = TRUE` has its check called as `check(value, REQ, args)`,
  where `args` are the arguments declared before it, already checked.
  `known_summary(REQ)` is the open project's summary if the main process
  has it. The `check_*()` functions themselves take a function name,
  arguments and a summary, never `REQ`.
- The project summary (`biom_summary()`, the BIOM-derived part of `BIOM`)
  is now: `tree`, `depth`, `depth_options`, `fields` (a list, in column
  order, of `{name, class: "categorical", levels}` or `{name, class:
  "numeric", min, max}`), `ranks`, and `taxa` (for each rank, its taxa,
  most abundant first). Gone: `cols`, `cols_cat`, `cols_num`,
  `col_types`, `col_options`, `rank_options`, `taxa_options`,
  `adiv_options`, `bdiv_options`, `clust_options`, `dist_options`,
  `ord_options`. The cache key prefix is `data2_`.
- `/api/project/upload` takes `inflate`; `/api/project/export` takes
  `what = "xlsx"`, checks `method` against rbiom's beta metric ids (a
  name such as "Bray-Curtis" is refused; the id is `bray`) and `rank`
  against the project's ranks (`"otu"` still means `".otu"`).
- `R/plot.r` no longer rewrites arguments; `plot_save_args()` is gone.
  The routes `/api/metadata/fields`, `levels` and `minmax` are untouched
  and now duplicate what the summary's `fields` carries.
- Found in rbiom during the step and fixed there since (rbiom 4.0.0,
  commit 86c21b7; `rbiom-schema-result.md` in the sessions' notes folder
  has the details): `fn_check()` now refuses deprecated arguments with a
  proper message; a bad metric is reported under `adiv` or `bdiv`; the
  `*_stats` and `*_table` functions are in `fn_schema()` (32 functions);
  choices that need an optional package are marked (`choices_needs`);
  entries say which counts they want (`counts`); `bhattacharyya` and
  `aitchison`, which give infinite or missing distances, stop with a
  message that says so. `aitchison` did that for every pair with ecodive
  2.3.1; ecodive 2.3.2 fixes it, and with it all four beta plots,
  `bdiv_clusters` and the distance export work through atima's routes
  (checked by hand, not in the test suite, which must also pass with an
  older ecodive). ecodive warns that it replaced zeros with a
  pseudocount of half the smallest count; rbiom's plots have no argument
  for it, and atima's users are not told.
- What atima does with those (after the step, same day):
  `plot_sample_set(fn)` reads rbiom's `counts` (`"unrarefied"` means the
  full file), so nothing in atima lists which functions get which file.
  `schema_unavailable(fn)` is the choices whose package is missing here;
  `schema_params()` leaves them out, and `check_fn_args()` refuses them
  after rbiom has matched the value, so any spelling is caught, in the
  main process. `has_package()` is the one place that asks what is
  installed. `/api/project/export` refuses `what = "xlsx"` without
  openxlsx. `rbiom_schema()` stops with "The installed rbiom is too old"
  if `fn_schema()` has no `counts`, and `atima()` calls it at start-up:
  rbiom's version cannot say this (`DESCRIPTION` still has `rbiom (>=
  4.0.0)` and `Remotes: cmmr/rbiom`). The schema is computed once per
  process (`schema_env`), installed packages included, so installing a
  package needs a restart.
- Verified by tests only, in-process and through real workers. Not
  verified: the routes over HTTP against a running server (the earlier
  steps' curl smoke test was not repeated), anything in a browser, and
  the wording of the inflate warning, which is mine and should be read by
  Daniel.
- `R CMD check --no-manual --as-cran` on Windows: 0 errors, 0 warnings,
  1 note, the CRAN incoming note (new submission, the `Remotes` field,
  the README's `http://127.0.0.1:8080` URL, the pkgdown URL that is not
  published yet). None of it comes from this step; CI turns the incoming
  check off.
- The worker pool tests (`test-jobs.R`, `test-async.R`) were unreliable
  on Linux, most of all with R 4.5, and CI failed there after this step
  was pushed. The cause is older than this step: the commit before it
  (9560f9d) fails the same way 3 times out of 3 in a `rocker/r-ver:4.5`
  container. Two races, both in the tests, not in `R/jobs.R`: a worker
  that has just connected, or is still unwinding a stopped job, may not
  answer `mirai::everywhere()`, so a roll call came back short; and a job
  could be replaced after it was handed to a worker but before its code
  ran, so its `on.exit` never fired. Fixed in b45f4fa and 18b39ff
  (`worker_pids()` retries; tests wait for the job's own "running"
  marker). After that: CI green on all four jobs, and 76 of 78 runs of
  the two files pass in the R 4.5 container with no failed expectation.
- Still open, for step 10: the other 2 of those 78 runs hung. One
  stopped between `test-jobs.R:368` and `:372`, which is `pool_stop()` on
  a pool with one running and one queued job (`mirai::stop_mirai()` then
  `mirai::daemons(0)`; mirai 2.7.4, nanonext 1.10.4). It did not come
  back in 60 further runs with trace messages in `pool_stop()`, so which
  call blocks is not known. Not seen on Windows or with R 4.6. If it is
  real it would show as a server that does not exit on shutdown while a
  job is running, and as a CI job that runs until GitHub's time limit;
  a `timeout-minutes` on the CI job would bound the latter. One earlier
  run in the same container also had 16 failures starting at
  `test-jobs.R:186`; it was not captured in detail and did not recur.

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

- From step 6: what the renderer works from.
  - `POST /api/schema` (no session needed, no arguments) answers
    `{rbiom, hash, functions, palettes, save, subset}`. It is the same
    for every project, so fetch it once per page load. `hash` identifies
    its rbiom part and is what to key a cache on: rbiom's version stays
    4.0.0 while its schema changes, and the metric lists come from
    ecodive. (It does not cover atima's own labels or which packages the
    server has.)
  - `functions.<fn>` is `{fn, use, area, label, returns, sample_set,
    rules?, params}`. `sample_set` is `"full"` or `"rare"`: which of the
    project's two files the function is given (`"full"` for the
    rarefaction plots and `taxa_forest`), for telling the user what a
    figure was made from. Choices and parameters that need a package the
    server lacks are already left out.
    `use` is `"plot"` (send to `/api/plot` as `plot_fn`) or `"clusters"`
    (send to `/api/metadata/add_clusters` as `cluster_fn` with
    `cluster_args` and a `name` for the new field). `area` is `alpha`,
    `beta`, `taxa` or `rarefaction`, for the menu. `rules` is, for
    `taxa_forest`, `[{"one_of": ["stat.by", "regr"]}]`: exactly one of
    the two must be set.
  - `params` is a list in rbiom's argument order. Every entry has
    `name`, `label`, `group` (`"basic"` or `"advanced"`), `type` and
    `desc` (a one-line description, for the tooltip). The rest is
    rbiom's and is present only when it applies: `default` (`null` means
    "leave it out"), `default_note`, `null` (what leaving it empty
    means), `choices`, `min`, `max`, `max_n` (how many values; absent
    means any number), `per_side`, `class` and `coerce` and `ops` for
    fields, `forms`, `by`, `palettes`, `when`, `note`. The meaning of
    each is in rbiom's help for `fn_schema()`.
  - `type` is one of `logical`, `integer`, `number`, `string`, `choice`,
    `layers`, `field`, `rank`, `taxa`, `metric`, `aesthetic`, `palette`,
    `tracks`. The data-dependent ones are filled in from `BIOM`: `field`
    from `BIOM.fields` (offer those whose `class` matches the
    parameter's; with `coerce`, numeric fields are accepted too but offer
    the categorical ones), `rank` from `BIOM.ranks`, `taxa` names from
    `BIOM.taxa[rank]`, and for `metric` hide the choices with `phylo:
    true` when `BIOM.tree` is false.
  - `when` is the visibility rule: a list of conditions that must all
    hold for the parameter to have any effect, each `{param, is | is_not
    | has_any | is_null | not_null}`, compared with the other control's
    current value in rbiom's canonical form (layer names such as `box`,
    not letters; metric ids). Hide or grey out the control otherwise.
  - Send only what the user changed; anything left out takes rbiom's
    default. Sending a parameter the function does not have, or `cpus`,
    is a 400.
  - `save.params` describes `save_args` the same way (`device`, `width`,
    `height`, `units`, `dpi`, `scale`); `save.pixels` is the allowed
    range of each side in pixels. `subset_args` is `{cat: {<field>:
    [values to keep, in display order]}, num: {<field>: [lowest,
    highest]}}`, built from `BIOM.fields`.
  - `palettes` is `[{name, kind, colors}]` with `kind` `discrete`,
    `sequential` or `diverging`; an `aesthetic` or `palette` parameter's
    `palettes` says which kinds suit it. A `-` before a name reverses it.
  - A rejected request is a 400 whose message starts "Argument
    'plot_args' ..." and usually continues with rbiom's own sentence,
    which names the parameter and the valid choices. Show it as text.
  - Everything in `BIOM.fields`, `BIOM.ranks` and `BIOM.taxa`, every
    stats table cell from `/api/plot`, and any error message can contain
    text from the user's file. It is JSON text, not HTML: insert it with
    text nodes. (Only the two table routes and the `thead` routes send
    HTML, as step 5 noted.)
  - Uploading: if `/api/project/upload` answers 400 with `error.code ==
    "confirm_inflate"`, show `error.message` (it explains what scaling
    does and warns about it), and if the user agrees send the same file
    again with the form field `inflate=true`.
  - The old `BIOM` keys the dead `js/` and `modules/` code reads
    (`cols`, `col_types`, `col_options`, `rank_options`, `taxa_options`,
    `adiv_options`, ...) no longer exist. The routes
    `/api/metadata/fields`, `levels` and `minmax` still work but the
    summary now carries the same information; drop them if the new
    front end does not call them.
  - The default image is 400 x 300 px at 100 dpi. With `units = "px"`
    the `dpi` only scales text and lines; a figure that does not fit
    gets a 400 saying the image is too small.

Decisions for Daniel: review of the control layout once a first version runs.

**Done. Decisions are in the decision log. Notes for later steps:**

- Where things are, under `inst/www`. `index.html`: the shell (navigation,
  top bar, main area); `{{atima_version}}` and `{{rbiom_version}}` are
  filled in by `index_html()` in `R/run.r`. `css/app.css`: every style.
  `js/main.js`: starts the session, builds the navigation from the
  schema, shows the page the address names. `js/store.js`: the state
  (`conf`, `biom`, `tree`, `schema`, `sessionKey`, `args`, `subset`,
  `save`, `fit`, `route`) with `get`, `set` and `on`. `js/api.js`:
  `call()` for every request (session key, a new session on 401, what
  responses say about the session goes into the store), the heartbeat,
  and cancelling jobs when the page closes. `js/schema.js`: what the
  schema means, as pure functions (`effective`, `active` for `when`,
  `payload`, `problems` for `rules` and required parameters, `prune`).
  `js/controls.js`: the one renderer, an editor per parameter `type`.
  `js/widgets.js`: dialogs, notices, the searchable picker, tabs.
  `js/tables.js`: the server-paged table and the in-page statistics
  table. `js/actions.js`: upload, save, publish, new link, sign in and
  out. `js/pages/*.js`: one module per page, each exporting
  `show(container, argument)` and returning `{onBiom, destroy}`.
- To add a page: a module in `js/pages/`, an entry in `pages` in
  `js/main.js`, a link in `buildNav()`. A page that returns no `onBiom`
  is drawn again whenever the open project changes.
- To support a new parameter type from rbiom: add an entry to `editors`
  in `js/controls.js`. An unknown type falls back to a text box. A new
  function or parameter of a known type needs no front-end change.
- Inserting text. `h()` in `js/dom.js` makes elements and inserts strings
  as text nodes. HTML is inserted in exactly two places, which
  `tests/testthat/test-frontend.R` counts: `serverHtml()` (descriptions,
  table header rows, highlighted code; through DOMPurify) and the cells
  of the server-paged table (escaped by the server, DOMPurify with no
  tags allowed).
- The page's Content-Security-Policy is `default-src 'self'` with no
  inline script or style. So: no `style="..."` or `on...=` attributes in
  HTML, no inline `<script>`; set styles from script (`element.style`),
  which the policy does not restrict. `tests/testthat/test-frontend.R`
  also checks that every file `index.html` and the scripts name exists,
  that every script is reached from `main.js`, that no file names another
  host except as a link, and that each vendored file is in
  `inst/www/assets/LICENSES.md`.
- There is no JavaScript test runner (no Node toolchain, by decision).
  The front end is checked by those R tests and by hand in a browser.
  `js/schema.js` is pure and would be the first thing worth testing if
  that changes.
- Back-end bugs that using the app in a browser exposed, each fixed with
  a test:
  - JSON responses rounded numbers to four decimal places, so p-values in
    statistics tables arrived as 0 (`response()`, `digits = NA`).
  - `/hmp50?utm_source=x` answered 400 with a JSON body: the page routes
    were strict about arguments. They are `strict = FALSE, html = TRUE`.
  - Static files had no `Cache-Control`, so browsers ran old scripts
    after the files changed (`static_paths()` in `R/run.r`).
  - "Save a copy" stored the copy's `created_utc` as a number of seconds
    (a time read by `db_query()` was bound back as a number). From then
    on that user's project tree, and so every page load, failed with a
    500. Fixed three ways: the copy gets its own creation time,
    `db_query()` binds times as text, and migration
    `inst/sql/005_dates.sql` (schema version 5) rewrites such dates. The
    same code was in 5.0.x, so production databases may hold such rows.
  - The metadata and taxonomy tables sorted every column as text, so 100
    came before 9 (`dt_page()` in `R/tables.r`).
  - An upload's title kept endings such as `.tsv` (`upload_title()`).
  - `index.html` was read while the package was being built
    (`static_index_html` was a value, not a function); it is read when
    first asked for.
- For rbiom (not worked around): the ggplot2 code of a box plot with
  p-value brackets writes the label positions as hexadecimal
  floating-point numbers (`.y = c(0x1.0237fa89e60fp+2, ...)`), which runs
  but is unreadable. Also seen, not a bug: a file whose counts were
  divided by four imported, after the inflate confirmation, with 35 taxa
  and a depth of 1; the warning's wording is still mine and unread.
- Verified in a browser (the app's built-in browser pane, Chromium;
  Windows; hmp50 and gems), `auth = "none"`: page load and navigation;
  every one of the 14 plot functions drawn at least once; a `when` rule
  (shapes appears with the dot layer); the `one_of` rule of
  `taxa_forest`; a required field chosen automatically; statistics and R
  code tabs; palettes with swatches, a color and a shape per group; a numeric
  sample filter; depth change; `bdiv_clusters` adding a field; metadata
  and taxonomy tables, sorting header, numeric/categorical switch;
  upload, including the `confirm_inflate` exchange; replacing the
  metadata; save, save a copy; the project tree (new collection, drag
  and drop, delete the open project); stop (the server logged the job
  cancelled); a 504 with a 3 second limit; the start-up failure page.
  `auth = "oidc"` with a mock issuer over HTTP: sign-in, sign-out, a
  refused sign-in (styled page), sharing search and grant, the ORCID iD
  (a test user's issuer was set to `https://orcid.org` in the database),
  publish, unpublish, new link, a viewer's and an administrator's view.
- **Not verified in a browser**, or only in part: the file chooser (files
  were handed to the page as a synthetic drop event, and the metadata
  file through the app's own `call()`); whether the browser saves a
  downloaded figure or export (the requests succeeded and the export's
  contents were read back, but the save itself was not observed); a 503
  (queue full); the heartbeat and a session expiring after 24 hours;
  the abort sent when the tab closes; patterns chosen by hand;
  `taxa_clusters`; Excel and BIOM exports; tree upload; the
  description editor's buttons; sharing as a viewer of a private
  project; any browser other than Chromium, and narrow windows; sign-in
  against Globus Auth or ORCID themselves.
- Left as it is, and worth knowing: `/api/sharing/editors` is not called
  by the front end (the list route covers it). The database columns
  `collections.jstree_text` and `jstree_icon`, and `projects.jstree_icon`
  and `projects.editors`, keep their names; the tree's node `icon` field
  is sent and ignored. `inst/www/js/migration.js` is still the untouched
  step 8 reference and is the one script not reached from `main.js`.
  Downloads on the summary page are made from the saved project, not the
  working copy, and the page says so.
- To run the app from source while editing it, start `atima::run()` after
  `pkgload::load_all()` with the pool given an `init` that loads the
  package from source in each worker (as `local_test_pool()` does in
  `tests/testthat/helper-db.R`); `run()` itself has no such option.
  Edits under `inst/www` then show on reload; `index.html` is cached
  until the server restarts.

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

- From step 7: where the import goes in the front end. Add a page module
  under `inst/www/js/pages/` and a link in `buildNav()` (`js/main.js`),
  shown only when `store.hasAccount()`; use `call()` from `js/api.js` and
  the dialogs in `js/widgets.js`. A password field is safe to add: the
  page's Content-Security-Policy allows requests to this server only. A
  response that carries `tree` or `tree_node` updates the project tree
  without more code. `inst/www/js/migration.js` is the only old script
  left; it uses jQuery and globals that no longer exist, so read it for
  what it did and delete it when this step is done (a test in
  `tests/testthat/test-frontend.R` names it as the one exception to
  "every script is reached from main.js"). The schema is at version 5;
  the next migration is `inst/sql/006_<name>.sql`.

Decisions for Daniel: how old MariaDB data is supplied (offline conversion to
SQLite vs. live connection); whether shared-project permissions are imported
or only ownership. **Needed from Daniel before this step:** a database
snapshot (or a small synthetic one with the real schema) for each source
version, plus a test account for each.

**Done, for atima 2 only. Decisions are in the decision log. Notes for
later steps:**

- **Tested against the live site's data (2026-11-13).** Daniel supplied
  a `mysqldump` of the live atima 2 database (MariaDB 10.3, taken with
  the commands in the session's notes) and one account. It was restored
  into a throwaway `mariadb:10.11` container, converted with
  `legacy_convert()` through `RMariaDB` (35 seconds; 368 accounts with
  projects, 5,152 projects, 19,407 objects, an 854 MB file), and
  registered with a running server. The account's password verified,
  its 73 projects were listed, and all 73 were imported, first through
  the worker function and then through the running server's routes, and
  each was read back with rbiom. Eight needed their counts scaled.
  What this did and did not show:
  - The user key: the "complete groups of four" candidate opened this
    account's private key. The "nothing decoded" candidate, for accounts
    whose hash has a `.` early on, has not met real data, because one
    account's password is all there was. If such an account cannot
    import, the message and log line described below will say so.
  - Old initialisation vectors: 57 accounts and 1,499 small objects in
    the dump have 16-byte vectors, of which the first 12 are used.
    Whether this account's projects include such objects was not
    checked one by one; all 73 decrypted.
  - `RMariaDB` returns the ids as 64-bit integers and the dates as
    times; the converter's coercions handled both.
  - Time: the median project took 5 seconds, but seven took over a
    minute and the longest 265 seconds; those have 50,000 to 120,000
    taxa. Hence the background import and its own time limit.
  - Found and fixed: a wrong stored MD5 on a readable project, and
    samples without a metadata row being dropped (decision log, (j)
    and (k)).
  The dump, the converted file and the account are in the gitignored
  `archive/legacy/` on the dev machine. They are real users' data.
- **The user key.** atima 2 computed
  `sha256(base64_decode(substr(bcrypt::hashpw(password, key_salt), 30, 61)))`.
  Those 31 characters are in bcrypt's own alphabet, not base64. OpenSSL
  of that time decoded the complete groups of four (28 characters, 21
  bytes) or, if a `.` was among them, nothing at all, in which case the
  key is the SHA-256 of nothing: the same for every such account, about
  a third of them. Today's `openssl` package refuses the text.
  `atima2_user_keys()` returns the candidates and `atima2_verify()` takes
  the one that decrypts the private key. If the real data needs another
  candidate, add it there; a password that verifies but opens no key
  gives a 500 with "This account's encryption key could not be rebuilt"
  and a log line naming the old user id. (Worth knowing about the old
  site, not about this one: for those accounts the private key was in
  effect not protected by the password. That is inferred from OpenSSL's
  source and not confirmed on the old server.)
- Where things are. `R/legacy.R`: the setting (`legacy_setting()`,
  `legacy_register()`), the handlers `api_legacy_sources()`,
  `api_legacy_list()`, `api_legacy_import()`, the attempt limit
  (`legacy_charge()`, `legacy_settle()`), and `secret()` / `reveal()`.
  `R/legacy-worker.R`: `legacy_adapters()`, `work_legacy_list()`,
  `work_legacy_import()`. `R/legacy-atima2.R`: the adapter.
  `R/legacy-convert.R`: `legacy_convert()`, the package's second
  exported function. `inst/sql/006_legacy.sql`.
  `inst/www/js/pages/legacy.js`. `tests/testthat/helper-legacy.R` builds
  the synthetic database.
- To support another old format: write `verify(con, email, password)`,
  `projects(con, account)` and `fetch(con, project, dir)` for it, add
  them to `legacy_adapters()` under a format name, and have a converter
  write that name into the file's `meta` table. Nothing else changes.
- Routes, all for people with an account: `POST /api/legacy/sources`
  (`{sources: [{id, label}]}`); `/api/legacy/list` (`source`, `email`,
  `password`; answers `{projects: [{id, title, created, level,
  status}]}` with `status` `new`, `shared` or `have`);
  `/api/legacy/start` (the same plus `projects`, a list of old ids, and
  `inflate`; starts the background import and answers as `status`
  does, or 409 if the person already has one running);
  `/api/legacy/status` (`tree`, default false; answers `{active,
  source, projects: [{id, title, state, message}], tree?}` with `state`
  one of `queued`, `running`, `imported`, `added`, `have`,
  `needs_scaling`, `failed`, `cancelled`); `/api/legacy/cancel`. A
  wrong email address or password is a 400 with `error.code ==
  "wrong_credentials"`, the limit a 429. `CONF.legacy` tells the page
  whether to show the link.
- How a background import runs. `api_legacy_start()` checks the
  password with a job like any compute route, then makes a batch in
  `REQ$LEGACY` (an environment in the app state, by user id) and
  returns. `legacy_advance()` gives the batch's next project to the
  pool with `pool_submit()` (no session, no supersede, its own time
  limit), `legacy_record()` writes the result in a transaction of its
  own, and the two take turns through `later::later()` until nothing is
  queued. A full queue (503) is retried every 5 seconds. A project that
  fails for a reason nobody planned gets the state `failed` with an
  error id, and a `legacy_import_failed` line in the log. New log
  events: `legacy_start`, `legacy_list`, `legacy_import`,
  `legacy_import_failed`, `legacy_done`. In the browser,
  `watchImport()` in `js/pages/legacy.js` polls the status every 3
  seconds while an import runs, from whichever page is open (`main.js`
  starts it), and fetches the project tree when a project has arrived.
- `arg_secret()` is a new argument type: the handler gets the value
  wrapped in an environment (`secret()`), which cannot be printed,
  deparsed into a logged call stack, or bound as an SQL parameter by
  accident; `reveal()` unwraps it, and only the adapter does. Use it for
  anything of the kind that later steps accept (step 11's tokens).
- Errors a worker meets after it found the password right are returned
  as a value and turned into a response with `error_response()`, not
  raised: raising would roll back the transaction that takes the counted
  attempt back. `legacy_refused()` and `legacy_error()` do this.
- `work_import()` was split: `import_biom(ctx, full_biom, orig, title,
  inflate, depth)` is the part that stores a dataset, and the legacy
  import calls it with the rebuilt object, so a rebuilt project goes
  through the same code as an upload (including `confirm_inflate`).
- Verified in a browser (the app's built-in browser pane, Chromium;
  Windows; `auth = "none"`; a server installed in a scratch library with
  the synthetic file registered, and the synthetic account): the link in
  the navigation, a wrong password and its message, the list of
  projects, starting an import of three and leaving for a plot page
  while it ran (the figure was drawn, and the notice said when the
  import had finished), the result (one imported, one waiting for
  agreement to scale, one damaged and refused with a message), "Scale
  and import" after typing the password again, and the imported project
  opened with its old date, depth and edited metadata. The real
  account's import was driven over HTTP by a script, not typed into the
  browser: while its 73 projects were imported, a status request took
  about 30 ms and a box plot of another project about 0.4 seconds. The
  server log and data directory were searched for the password and the
  email address: neither is there. **Not verified in a browser:**
  cancelling a running import (tested), the real account's projects
  on screen, `auth =
  "oidc"` (the sign-in card, a second person being added to a project;
  both are covered by tests), the lock after five wrong passwords (also
  tested), and more than one registered installation.
- Left as it is: an unclaimed password account in a database upgraded
  from 5.0.x keeps its row and projects for ever; `adopt_guest()` was not
  generalised. The inflate warning shown for an imported project says
  "Upload the original counts if you have them", which an importer
  cannot do.

## Step 9: MCP server, local

An MCP (Model Context Protocol) server lets AI apps (Claude Code, Claude
Desktop, claude.ai connectors and others) use atima as a set of tools:
describe a project, run statistics, draw a figure. This step adds it for
`auth = "none"` only; step 11 adds sign-in for shared servers. The
decision log says why it is added beside the browser API instead of
after reworking sessions and auth.

- Transport: Streamable HTTP on the existing server, one route
  `POST /mcp` taking JSON-RPC 2.0 (`initialize`, `tools/list`,
  `tools/call`, `ping`). Answer each request with `application/json`;
  the tools are request and response, so no SSE stream is needed
  (`GET /mcp` answers 405). Notifications such as
  `notifications/initialized` get 202 and no body. Read the MCP
  specification current at the time before starting; it changes often.
  The route exists only in `auth = "none"` (`modes = "none"`) until
  step 11.
- Permissions stay in one place: the route table declares `/mcp`, and a
  second, smaller table declares each tool (name, argument specs,
  permission, handler) and is checked the same way, so tool handlers
  still check nothing.
- Caller: in `auth = "none"` the caller is the local owner
  (`local_owner()`), with no cookie and no tab session. `check_host()` and
  `check_origin()` already apply, which is what the MCP specification asks
  of local servers against DNS rebinding.
- Project per call: each tool names its project by key. Find it with
  `key_project()` and check `project_access()` for the caller, as
  `resume_session()` does for a tab's open project. Tools work on the
  saved project, never on a tab's unsaved draft; `depth` is an argument,
  and `work_plot()` already rarefies to it.
- Jobs: reuse the worker functions (`work_plot()`, `work_summary()`,
  `work_metadata_*()`, `work_export()`), which take file paths, not
  sessions. The router already runs jobs without a session for the two
  download routes. Submit with no supersede key: a model may call several
  tools at once, and supersede would cancel all but the last with 409.
  Figures and exports need a directory that is not a tab's
  `server_temp` (`api_plot()` writes there now); give MCP callers their
  own under `temp_dir`, with the same 24-hour retention.
- Validate arguments with the step 6 schema function before submitting,
  as the browser's plot route does.
- First tool set, reading and computing only (no upload, save, publish,
  share or delete):
  - `list_projects`: projects the caller can open, with keys and titles.
  - `describe_project`: samples, depth range, metadata fields with types
    and levels, ranks, and whether there is a tree (UniFrac needs one).
  - `run_stats`: one of rbiom's `*_stats` functions. Small and fast, for
    screening many fields.
  - `make_plot`: the figure as an image (PNG), its stats table, the R
    code and the figure's URL.
  - `export`: a link to an xlsx or BIOM export.
- Results: keep them small. Cap long stats tables (taxa can run to
  hundreds of rows) and say in the result that rows were left out and how
  to narrow the request. Errors from the job layer (409, 503, 504, a
  rejected argument) become tool results with `isError: true` and the
  message a browser user would see, so the model can retry or change its
  call; a malformed JSON-RPC request is a protocol error.
- Prompt injection: metadata names and values, titles and descriptions
  are user data and go into the model's context. Return them as data
  fields in results, never inside tool names or descriptions. Keeping the
  tools to reading and computing limits what an injected instruction can
  do.
- Tests: JSON-RPC round trips in testthat (initialize, list, each tool, a
  rejected argument, a permission refusal, a notification). By hand:
  `claude mcp add --transport http atima http://127.0.0.1:8080/mcp`, then
  ask Claude Code to explore `hmp50`.
- Docs: a README section on connecting an AI app.

- From step 6: what is ready and what is not.
  - Ready: `check_fn_args(fn, args, summary)`, `check_save_args(args)` and
    `check_subset_args(args, summary)` in `R/schema.R` take no `REQ` and
    stop with a plain error whose message completes "Argument '<name>'
    ..."; `worker_check()` and `stop_arg()` turn that into the 400.
    `fn_json_schema(fn, summary = NULL)` gives a function's parameters as
    JSON Schema (`type`, `enum`, `minimum`, `maximum`, `default`, `anyOf`
    for parameters with several forms, label and description as
    `description`); with a summary, fields, ranks and tree-dependent
    metrics are listed as the project has them. Convert it with
    `jsonlite::toJSON(auto_unbox = TRUE, null = "null")`. It has not been
    run through a JSON Schema validator or shown to an MCP client.
  - The summary a tool needs is `work_summary()`'s `data`; its
    `fields`, `ranks`, `taxa`, `tree`, `depth` and `depth_options` are
    most of `describe_project`.
  - Statistics and tables: rbiom's schema now covers `adiv_stats`,
    `bdiv_stats`, `taxa_stats`, `taxa_da`, and the long-form tables
    behind the plots (`adiv_table`, `bdiv_table`, `taxa_table`,
    `bdiv_ord_table`), so `fn_check()` can check their arguments. atima
    does not expose them yet: each needs a line in `schema_functions`
    with a new `use` (such as `"stats"`), a route or tool, and a worker
    function. `plot_sample_set(fn)` already answers which file to give
    any of them. They use schema fields the plots do not, which
    `fn_json_schema()` ignores so far: `rules` with `any_of` and
    `when`/`requires`/`forbids`, `choices_when` (bdiv_stats `test`),
    and `extra` (values accepted besides field names: `".taxa"`,
    `".all"`). `distmat_stats` and `distmat_ord_table` take an R
    distance matrix and are of no use to a remote caller.
  - `work_plot()` takes `checked`: pass `FALSE` and it checks
    `plot_args` and `subset_args` itself against the files it is given,
    which suits a caller with no summary in memory.

Decisions for Daniel: the first tool list and names; the row cap for stats
tables; whether a later version may change data (upload, save).

**Done. Decisions are in the decision log. Notes for later steps:**

- **What differs from the list above.** The specification's current
  revision is 2026-07-28, and that is what was built: `server/discover`,
  `tools/list` and `tools/call`; no `initialize` and no `ping` (both are
  gone from the protocol; `initialize` is answered with an error naming
  the revision, `ping` with "method not found"). There are six tools, not
  five. Everything else is as listed.
- Where things are. `R/mcp.R`: the protocol (`mcp_post()`, the checks
  every request must pass in `mcp_check_request()`, `mcp_dispatch()`,
  `mcp_call_tool()`, how results and the two kinds of error are built).
  `R/mcp-tools.R`: `mcp_tool_table()`, `tool()` and `tool_arg()`,
  `tool_call()` (caller, project, permission, arguments, handler),
  `mcp_caller()`, and the handlers `tool_<name>()`. `R/worker-stats.R`:
  `work_stats()`. `R/access.R`: `caller_project()`, the one permission
  rule for a project named in a call. `R/schema.R`: the four statistics
  functions (`use = "stats"`), and `fn_rules()`, `rules_text()`,
  `rules_json_schema()`, `condition_text()`.
  `tests/testthat/test-mcp.R` and `helper-mcp.R`.
- What the router gained, for any route that needs it. `route(raw =
  TRUE)`: the handler gets `body` (raw) and `headers` instead of parsed
  arguments (`arg_body()`, `arg_headers()`). `job(failed = )`: a function
  of the error a job ended with that returns the response to send, so a
  caller with its own error format hears of time-outs, a full queue and
  worker crashes. `error_report()` in `R/errors.R` logs an error and
  returns `list(status, message, id, code)`; `error_response()` is built
  on it. `REQ$RPC`, if set, is logged with the request.
- How a tool call runs. `mcp_post()` reads and checks the message;
  `mcp_call_tool()` finds the tool; `tool_call()` asks `mcp_caller()` who
  is calling, has `caller_project()` open the project named in `project`
  (which stops if the caller may not use it), puts the result in
  `REQ$SESSION`, runs `validate_args()` over the tool's declared
  arguments exactly as for a route, and calls the handler. For the length
  of the call `REQ$SESSION` looks like a tab's session (user, project,
  the saved project's `full_bf_id` and `rare_bf_id`, `access`,
  `project_key`) without `session_id` or `session_key`. That is why
  `known_summary()`, `memo_get()`, `biom_path()` and the argument types
  `arg_fn_args()`, `arg_subset_args()`, `arg_rank()` and `arg_metric()`
  work unchanged, why the router does not reload a session after the job,
  and why jobs are submitted with no session and no supersede key.
- To add a tool: a `tool()` entry in `mcp_tool_table()` (its arguments
  made with `tool_arg(<arg_*()>, <description>, <JSON Schema>)`) and a
  handler `tool_<name>(REQ, <arguments>)` that returns `list(data)` or
  `list(data, image)`, or a job whose `finish` returns that. (An
  argument the model calls `function` reaches the handler as `fn`:
  R's code checker cannot read a function with a parameter of that name.) Tests fail
  until the handler takes exactly the declared arguments and
  `examples` in `test-mcp.R` has a call that satisfies the schema. A
  tool that changes data declares `read_only = FALSE` and the level it
  needs (`editor` for the named project), and is offered only when
  `config$mcp_writes` is true; `run()` needs an argument for that when
  the first such tool is written, and its handler must do its writing in
  `finish`, as the browser's handlers do.
- Depth. A call's `depth` rarefies for that call only: `work_plot()` and
  `work_stats()` store the rarefied file (it is in the cache, and the
  cleanup timer removes the stored file after a day, since no row
  refers to it) and nothing in the database changes. The R code in a
  result then loads `full.json` and calls `rarefy()`; without `depth` it
  loads `rare.json`. A `samples` filter is not part of that code; the
  code says so in a comment.
- Bugs found on the way, fixed with tests: rarefying to a depth no sample
  reaches was an internal error ("Matrix is all zeroes"); `rarefy_to()`
  now refuses it with a message, for the browser too. `work_plot()`
  reports a failed worker-side check under the caller's own argument
  names (`keys`).
- For rbiom (not worked around): `fn_schema()` gives `adiv`'s default as
  `"Shannon"` while its choices are lower-case ids (`"shannon"`); a model
  reading the JSON Schema noticed. The default of `layers` is likewise
  the letter form (`"x"`), not a name from the choices.
- `describe_project` reports `samples` from the `projects` table, which
  counts every sample; at the saved depth some are left out (hmp50: 50
  samples, 49 at depth 1,183). The result says how depths work, and a
  model worked it out, but a count at the saved depth would be clearer;
  the summary does not carry one.
- **Verified with a real MCP client** (2026-11-13, Windows): Claude Code
  2.1.325, added with `claude mcp add --transport http`, against a server
  installed in a scratch library and run with `auth = "none"`, `workers =
  2` and the two example projects. It connected (the server log shows
  `server/discover` then `tools/list`; no `initialize`), and, driven with
  `claude -p`, listed the six tools, listed the projects, described
  `hmp50`, called `describe_function` twice, ran `adiv_stats` and
  `taxa_stats` (200 rows, 10 returned, the note quoted back, rbiom's
  warning about comparisons it could not compute passed on), drew an
  `adiv_boxplot` and a `bdiv_ord_plot` and described what the images
  show, was refused a misspelled field with rbiom's message and corrected
  the call, and exported the metadata. The figure and table links were
  fetched with curl. The entry was removed from Claude Code afterwards.
  Also by hand with curl: `initialize` (400, -32022) and `GET /mcp`
  (405).
- **Not verified with a real client:** any app other than Claude Code
  (Claude Desktop, claude.ai, other vendors' apps); an app that only
  speaks an earlier revision (the refusal is tested, and was sent by
  curl, but what such an app shows its user was not seen); `export` of
  the larger formats and `taxa_da` through a client (tests cover them);
  a tool call that runs into the time limit or a full queue (tested
  through real workers and with a stand-in, not through a client); Linux
  and macOS (CI only).

## Step 10: Deployment, docs, load testing

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
- From step 8: the server image needs the `bcrypt` package if a legacy
  file is registered (the server refuses to start without it), and the
  legacy file needs a place outside the image, readable by the server
  only; it is as sensitive as the old database. It is never written to,
  so it can be mounted read-only. The proxy should rate-limit
  `/api/legacy/` like the sign-in routes: each check costs a worker
  about a second of bcrypt, and although a person is locked out after
  five wrong passwords, the lock is per account. The legacy-import
  vignette can start from the README section; it should say plainly
  that a forgotten old password means the projects cannot be recovered
  by anyone. The adapter has imported one real account's 73 projects
  (see the step 8 notes); when the public server opens, watch the log
  for `legacy_import_failed` and for "encryption key could not be
  rebuilt", which would mean an account whose key was derived the other
  way. A background import holds a worker for up to 15 minutes per
  project, one project per person at a time, so with `workers = 1`
  everyone's figures wait behind it: give the public server at least
  two workers. Imports are not counted by step 10's per-account job
  limit unless that is added to `legacy_advance()`. Stopping the server
  ends running imports (they can be started again).
  `legacy_attempts` rows older than a day are deleted when the next
  attempt is made, not by the cleanup timer.
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

- From the MCP decision (2026-11-11): per-account job limits. The queue
  is one first-come list for everyone (`10 x workers`, then 503), and
  steps 4 and 5 left per-client limits to the proxy. Limits by IP address
  at the proxy stop being enough once step 11 lets claude.ai and similar
  apps connect: their requests come from the app maker's servers, not the
  user's computer, so all their users would share one limit. And one
  agent that calls many tools at once can fill the queue for everyone.
  Add `user_id` to jobs (they carry `session_id` now) and cap each user's
  queued and running jobs in `pool_submit()`, answering 429 with a
  message to wait. This also gives browser users the fairness step 4
  noted is missing. The load test should include one user starting many
  jobs at once beside other users.
- From the MCP decision: the vignettes gain one on connecting an AI app
  to a local install (step 9's README section, expanded). Step 11 adds
  shared servers to it.
- From step 9: what the per-account job limit has to cover. A tool call's
  job has no `session_id`; the caller is `REQ$SESSION$user_id` when
  `mcp_call_tool()` returns its job, so that is where a `user_id` for
  `pool_submit()` comes from. The specification says servers must rate
  limit tool invocations; today the only limit is the shared queue (503
  as a tool result with `isError`, which a model may retry at once). A
  429 for one user's flood should be a tool result too (it will be, if
  it is raised as an `atima_http_error`). The load test should include an
  agent calling `make_plot` several times at once: each result carries
  the PNG as base64 inside JSON (about 50 kB for a box plot at the
  default size), built and sent by the main process.
- From step 9: the proxy must pass `/mcp` once step 11 opens it on a
  shared server, must not buffer or cache it (answers say `Cache-Control:
  no-store`), and must let the three request headers through
  (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`). Files for tool
  calls are under `/tmp/mcp/`, already covered by `/tmp/`. The image
  needs no new package: `jsonvalidate` is for tests only. New in the
  log: `rpc` on request lines for `/mcp` (`server/discover`,
  `tools/list`, `tools/call <tool>`, `notification`). The vignette on
  connecting an AI app should say, as the README does, that what a tool
  returns goes to the app's provider, and should name the protocol
  revision, since apps that only know earlier ones cannot connect.

- From step 6: optional packages decide what works on a server. rbiom
  only suggests them, so the image must install them itself: `openxlsx`
  (Excel export), `fillpattern` (the `patterns` parameter; atima leaves
  it out of the schema when the package is missing), `Rtsne` and `uwot`
  (tSNE and UMAP ordinations), `ggdensity` (the ordination's density
  layer), `lmerTest` (`strata` in `taxa_forest`), `ggbeeswarm` and
  `ggrepel` (nicer layers, with fallbacks), `h5lite` (HDF5 BIOM files), `svglite`
  (SVG figures). Without one of the first six, atima does not offer what
  needs it and refuses a request for it; nothing warns the administrator,
  so the image's package list is the place to get it right. The load test should include `taxa_forest` and the
  permutation tests at their default 999 permutations, which are the
  slowest requests the schema allows.
- From step 6: on Linux, stopping a pool that has a running job hung
  twice in 78 test runs (R 4.5 container; details in step 6's notes).
  Test shutdown under load on the server's own platform (stop the server
  while jobs run and while jobs are queued, many times), and give the CI
  job a `timeout-minutes`.

- From step 7: for the reverse proxy and the server image.
  - The app's page sets its own Content-Security-Policy (this server
    only, nothing inline) and `X-Frame-Options: DENY`. If the proxy adds
    a policy of its own, both apply, so it can only make things
    stricter: check figures (`/tmp/...`), fonts and the CSV download of
    a statistics table (a `blob:` address) still work if it does.
  - `/www` is sent with `Cache-Control: no-cache`: browsers ask each time
    and get a 304. The proxy may answer those itself but must not cache
    `/www` for longer, or an upgrade leaves old scripts running against
    the new server. `/tmp/<session key>/` file names never repeat.
  - The front end needs nothing from another host: no CDN, no fonts.
  - Public collections still cannot be made, renamed or deleted through
    the app; a publisher can only pick an existing one. The public
    server needs either routes for administrators or a documented SQL
    recipe (`INSERT INTO collections (user_id, jstree_text) VALUES
    (NULL, '<name>')`).
  - The load test should include the page itself: one page load is
    `index.html`, about 20 small static files, `/api/session/init` and
    `/api/schema` (about 60 kB; the same for everyone, so the proxy may
    cache it per atima version).
  - Not done: a "Support" or documentation page (the mock-up had a link),
    and the privacy and terms text, which needs a place in the app.
  - A local install upgraded from 5.0.x gets migration 005, which repairs
    creation dates that "save a copy" stored as numbers; with such a row
    the old server answered 500 to that user's every page load.

Decisions for Daniel: hosting details for the public server; privacy/terms
text; backup policy.

**Done. Decisions are in the decision log. Notes for later steps:**

- Where things are. `deploy/Dockerfile` (the server image; its
  `Dockerfile.dockerignore` lets only `DESCRIPTION`, `NAMESPACE`,
  `LICENSE`, `R`, `inst`, `man` and two scripts into the build, so
  `archive/` and `docker/` never reach Docker), `deploy/entrypoint.sh`,
  `deploy/backup.R`, `deploy/caddy/` (Caddy with the rate-limit module,
  and the Caddyfile), `deploy/compose.yaml`, `compose.legacy.yaml`,
  `.env.example`. `loadtest/`: see its `README.md`. `R/health.R`.
  `waiting()` in `R/jobs.R` and its branch in `handle_request()`.
  `server_timing()` in `R/router.R`. `pool_user_jobs()` in `R/jobs.R`.
  `api_public_*()` in `R/collections.r`, `check_public_nodes()` in
  `R/access.R`. `inst/www/js/pages/privacy.js`. `_pkgdown.yml`,
  `.github/workflows/pkgdown.yaml`, `vignettes/articles/*.Rmd`.
- The image: `rocker/r-ver:4.6`, 153 R packages, about 2.7 GB; a first
  build takes ten to fifteen minutes. It runs as user 10001 on a
  read-only root file system, with volumes for `/var/lib/atima` and
  `/var/tmp/atima` and a tmpfs `/tmp`. Building for an older R needs
  `--build-arg CRAN_REPO=...`, because rocker pins old R versions to a
  CRAN snapshot too old for rbiom 4 (its ecodive).
- `waiting(start, finish)` is for any handler that must wait for
  something other than a worker: `start()` returns a promise, the router
  answers with a promise and runs `finish` in a new transaction. Step
  11's token and metadata requests to other servers should use it.
- New routes: `GET /api/health`; `POST /api/public/create`, `rename`,
  `delete`, `move` (admin). New settings: `jobs_per_user`, `operator`,
  `contact`. `CONF` gained `session_hours`, `guest_days`, and `operator`
  and `contact` when set, with accounts only. New log event: `unhealthy`.
  A 429 from the job limit has the message "Too many of your requests are
  waiting or running at once. ..." and is a tool result for an MCP call.
- **Verified on the development machine only** (Windows 11, Docker
  Desktop 29.9 on WSL2; 2026-11-13 and 14): the image builds from a clean
  context; the stack starts from `cp .env.example .env` and `docker
  compose up -d --build`; the app loads through Caddy in a browser; a
  whole sign-in in a browser through Caddy and the mock provider
  (`loadtest/compose.mock.yaml`), and by curl over Caddy's local HTTPS;
  a visitor's own `X-Forwarded-Proto` is ignored (the cookie stays
  `Secure`); `docker stop` ends the server in 2 to 3 seconds with exit
  status 0, for SIGINT and for SIGTERM, with the database checkpointed
  (no `-wal` file left); a backup, a refused restore while the server
  runs, a restore, and the server starting on the restored data; a
  5.0.x data directory (the test fixture) upgraded in the container, with
  its `.bak` copy.
- **Not verified, and waiting for the real server:** a certificate from
  Let's Encrypt and HSTS; the rate limits under real traffic (only that
  the configuration loads, and that the load test is refused nothing
  with them raised); `ATIMA_TRUSTED_PROXIES` behind a real proxy; the
  legacy mount (`compose.legacy.yaml` was written, not run); the nightly
  backup at its hour (the loop's `backup` step was run by hand) and
  backups to a directory outside Docker; a secret given as a file; Linux
  as the host rather than Docker Desktop; sign-in against Globus Auth or
  ORCID; the administrators' tree controls with a real administrator
  sign-in (they were tried with a guest row flagged as administrator),
  and drag and drop in the public tree. The privacy text is a draft.
- **The Linux shutdown hang did not show.** `loadtest/shutdown-stress.sh`
  stops a busy pool in a fresh R process per round, in six variations
  (one running and one queued, as in the test that hung; stopped before
  the jobs' code started; four workers and a long queue; ...), each call
  of `pool_stop()` traced. 300 rounds with R 4.6.2 and 300 with R 4.5.3
  (both mirai 2.7.4, nanonext 1.10.4, in the image): none hung or failed.
  So the cause of the two hangs seen in step 6 is still not known; what
  is known is that it is rarer than about 1 in 600 pool stops with these
  versions, and that the two hangs were in a test process that had
  already started and stopped other pools, which these rounds do not do.
- **A different shutdown fault was found and fixed.**
  `loadtest/stop-under-load.sh` stops a whole server container while six
  simulated people and two AI apps keep one or two workers busy. In its
  first 30 rounds one stop was not clean: the server kept answering
  requests after the signal until Docker killed it at 30 seconds. An
  interrupt that reaches R while it runs a callback of the event loop (a
  request handler, the end of a job) only ends that callback, and
  `httpuv::runServer()` carries on. `R/shutdown.R` now has
  `interruptible()`, which every such callback runs in and which notes
  the request to stop, and `serve()`, a loop in place of `runServer()`
  that ends when it sees the note. After that, 60 stops of 60 were clean,
  in 1 to 6 seconds. A callback added later (a `later::later()` or a
  promise handler in the main process) should run in `interruptible()`
  too; the legacy import's callbacks do not yet. The CI job now has
  `timeout-minutes: 45`, and a server that did hang on the way down would
  be killed by Docker after `stop_grace_period` (30 s) with the database
  intact, since SQLite's write-ahead log survives a kill.
- **Load test** (`loadtest/README.md` has the method, the full tables
  and how to run it again; `loadtest/results/` the data). Hardware: one
  desktop, Intel Core i5-9600K (6 cores, no hyper-threading), 64 GB;
  Docker Desktop on WSL2 with 6 CPUs and 31 GB; server, Caddy, mock
  provider and load generator all on that machine; one CPU core per
  job. Summary:
  - The main process stayed responsive in every run, including those
    where most jobs were turned away: a whole page load took at most 0.4
    seconds at the 95th percentile, and a request that needs no worker
    at most 0.3 seconds. All 6,108 page, static file, schema and session
    requests succeeded.
  - Capacity is the workers, and one kind of job sets it. Most jobs run
    for one or two seconds; PERMANOVA with 999 permutations on the
    1,006-sample example ran 31 to 36 seconds (median; 48 at most) on
    one core, against under a second on the 50-sample one, and holds its
    worker for that time. One action in ten was such a job.
  - Ten people acting every 5 seconds: with 1 worker the median wait
    for a worker was 5.0 s (95th percentile 65 s), with 2 workers 0.3 s
    (28 s), with 4 workers 0.0 s (12 s); nobody was turned away.
  - Thirty people acting every 20 seconds: 1 worker turned away 130 of
    200 jobs (503), 2 workers 25 of 161, 4 workers none (median wait
    3.0 s, 95th percentile 31 s). Thirty people every 5 seconds: 4
    workers served all 204 jobs with a median wait of 15.5 s.
  - No job reached the 60-second limit; the largest came within 12
    seconds of it.
  - One account starting 40 exports at once: 16 accepted and 24 answered
    429 where the queue had room; where other people's jobs had filled
    the queue, 503 like everyone else's.
  - Ten sign-ins at once through a provider that takes 2 seconds: all
    succeeded (2.3 s median, 4.3 s at most) and the probe was answered
    within 0.26 s. This is after sign-in was moved to the background;
    before, each would have stopped the server for 2 seconds.
  - Two AI apps calling `make_plot` six times at once, five times: all
    180 calls succeeded; median 8.8 s with 1 worker, 4.2 s with 2, 2.2 s
    with 4; 59 kB per answer.
  These are one machine's numbers with the generator on the same
  machine. Run the series again on the real server before it opens.
- Seen in the full test suite, once, while two other heavy jobs ran on
  the machine: a trivial job in `test-jobs.R` passed its 3-second limit,
  and the four tests after it failed with "object 'worker_run' ... not
  found", which is a worker whose `pkgload::load_all()` was cut off by
  that time limit. It is a weakness of the test pool (workers load atima
  from source inside the job's time limit), not of the server, whose
  workers load the installed package before any job. The file passes on
  a quiet machine.

## Step 11: MCP server, shared (sign-in), and tools that change data

Step 9's `/mcp` route for `auth = "oidc"`, so people can connect claude.ai
and other apps to the lab's server and work with their own projects.

- What MCP asks of a server that needs sign-in: it is an OAuth 2.1
  resource server. A request without a valid token gets 401 with a
  `WWW-Authenticate` header pointing at the server's Protected Resource
  Metadata (`/.well-known/oauth-protected-resource`, RFC 9728), which
  names the authorization server. The app signs the person in with the
  authorization code flow and PKCE, asks for a token for atima's `/mcp`
  URL (a `resource` indicator, RFC 8707) and sends it as
  `Authorization: Bearer`. Apps identify themselves with a Client ID
  Metadata Document or by Dynamic Client Registration (RFC 7591), or use a
  client id registered by hand. That was the specification in late 2025;
  read the current one before starting.
- Likely design: atima is its own authorization server. Its
  `/oauth/authorize` page signs the person in through the existing OIDC
  login (Globus or ORCID), shows which app is asking and what it will be
  able to do, and on approval issues a code. `/oauth/token` exchanges the
  code and PKCE verifier for an access token and a refresh token. Tokens
  are stored hashed, as `auth_tokens` are, with the app, the user, the
  resource and an expiry. The other way, naming Globus Auth itself as the
  authorization server, is less code but leaves out ORCID servers and
  depends on Globus supporting what MCP apps need.
- Router: on `/mcp` a bearer token is the only credential. Cookies are
  ignored there, and bearer tokens are accepted nowhere else. The caller
  is the token's user, and step 9's tool table applies the same
  `project_access()` rules.
- Opening a project by its private key gives a browser a permanent view
  grant (`open_by_key()`). Decide whether a key named in a tool call does
  the same; an agent should not quietly add projects to someone's tree.
- Disconnecting: a list of connected apps in the account menu, each with
  a "disconnect" control that revokes its tokens.
- Limits: step 10's per-user job cap applies to token callers. The proxy
  rate-limits `/oauth/` and `/.well-known/` as it does `/auth/login`.
- Prompt injection matters more here: any signed-in editor can publish,
  so a public project's text can be written to steer other people's
  agents. With the tools that change data (below), an injected
  instruction could share, publish or delete; that section says what
  stands in its way.
- Tests: extend the mock issuer in `tests/testthat/helper-oidc.R` to a
  whole connect flow (metadata, authorize, token, a tool call, refresh,
  disconnect). By hand: add the deployed server as a custom connector in
  claude.ai (it needs the public HTTPS address) and explore a project.
- Docs: the MCP vignette gains connecting to a shared server.

- Tools that change data (added by Daniel on 2026-11-14): upload, save,
  share, publish and delete, so that an agent can do what a person can do
  in the browser. Step 9 left room: each tool declares its permission and
  whether it only reads, and writing tools are offered only when
  `mcp_writes` is on (`run()` sets it to `FALSE` and has no argument for
  it yet). They apply to both modes: on a local install the caller is the
  local owner, on a shared server the token's user.
  - Permissions are the browser's, declared in the tool table and checked
    there, never in a handler: upload needs an account; save needs an
    editor grant; share and delete need what the sharing and delete
    routes need; publish needs an editor who is not a guest. The server's
    refusals stay the same (the last editor cannot be removed, a public
    key that is taken or reserved). Reuse the route handlers' functions
    rather than writing the rules twice.
  - Consent by scope: the token says whether the app may only read or
    may also change things, and the approval page says so in words
    ("see your projects and run analyses" against "upload, change, share,
    publish and delete your projects"). A person can connect an app for
    reading only. `tools/list` then depends on the token, so it must say
    `cacheScope: "private"`.
  - Tell the app what each tool does with the specification's tool
    annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`), so
    that apps which ask the person before a destructive call do so.
    These are hints: an app may ignore them, so they are not the
    protection.
  - Upload: a tool's arguments are JSON, and a BIOM file can be many
    megabytes. Options to weigh: the file as base64 in the call (simple,
    small files only, and it passes through the model's context in some
    apps); a one-use upload address the tool returns, to which the app or
    the person sends the file; and, on a local install only, a path on
    the same machine. Do not fetch a URL the caller names from the
    server (it would let a caller make the server request addresses
    inside the lab's network). The `confirm_inflate` exchange for counts
    that are not whole numbers needs an argument of its own.
  - Save: tools work on saved projects, with no tab and no draft, so
    "save" has to be defined as explicit changes: title and description,
    rarefaction depth, added cluster fields, edited metadata, and "save a
    copy" of a subset as a new project. Say in each result exactly what
    changed.
  - Share: grant, change and remove access, and "new link". The user
    search returns other people's names (and ORCID iDs); decide whether
    an agent may search, or must be given the person exactly.
  - Publish and unpublish, with the warnings the browser shows (a
    published project is readable by everyone; unpublishing a project
    nobody has a grant on leads to its deletion).
  - Delete: find out first what deleting does today and whether anything
    can be recovered. Recommended: deleted projects are kept for a
    period and can be restored from the browser, for people and agents
    alike, before any delete tool exists.
  - What stands in the way of an injected instruction. Text in a
    project (titles, descriptions, metadata values) reaches the model
    beside these tools, and sharing or publishing is a way to send
    private data to someone else. The read-only scope and the hints are
    the first two layers. For the actions that cannot be undone or that
    expose data (share, publish, delete, new link), choose a third: the
    tool only records a request, and the person confirms it in atima's
    own pages; or the protocol's way of asking the person through the
    app (elicitation), if the revision current then offers it to
    stateless servers and the apps that matter support it. Upload and
    save can act at once, since the person can see and undo them.
  - A record of what agents did: every change made through a tool is
    recorded with the app's name, the tool and the project, and the
    person can read it next to their list of connected apps. Step 12's
    usage tables count these as actions with the `mcp` interface.
  - Limits: step 10's per-user job cap covers uploads; add a cap on
    changes per token per hour, so that a loop cannot share or delete in
    bulk.
  - Tests: each writing tool allowed and refused by permission, by a
    read-only token and with `mcp_writes` off; the confirmation step for
    the guarded actions; nothing is changed by a call that is refused; a
    project's text containing an instruction changes nothing by itself
    (the tools treat it as data); the record of changes.

- From step 9: what is there to build on, and what has to change.
  - The protocol is revision 2026-07-28, stateless: no handshake and no
    session, so a bearer token is checked on every request and there is
    nothing to tie it to. Read the authorization part of the revision
    current then; in 2026-07-28 it prefers Client ID Metadata Documents
    and has deprecated Dynamic Client Registration, and asks clients to
    check `iss` in the authorization response (RFC 9207).
  - Who is calling is decided in one function, `mcp_caller()` in
    `R/mcp-tools.R`, which returns `list(user_id)`. Today it is the local
    owner and refuses any other mode. Make it read the bearer token
    (`mcp_post()` has the headers; pass them on, and take the token with
    `arg_secret()`'s `secret()` so it cannot be logged). A missing or bad
    token must be a 401 with `WWW-Authenticate` from `mcp_post()` itself,
    before the message is looked at, not a tool result.
  - The route: `POST /mcp` and `GET /mcp` are declared with `modes =
    "none"`. Opening them for `oidc` is a change to those two lines.
    `check_origin()` already refuses a POST from another site's page.
  - Nothing else in the tools should need to change: `caller_project()`
    applies `project_access()` for whatever user `mcp_caller()` names,
    never makes a grant, and gives one answer for "no such key" and "not
    yours". A guest cannot be a caller unless `mcp_caller()` lets one be,
    which is the "public projects without signing in" decision.
  - `tools/list` and `server/discover` say `cacheScope: "public"`. That
    is right while every caller is shown the same tools. If the list
    comes to depend on the token (scopes, or `mcp_writes` per user), it
    must say `"private"`.
  - Links in results (`figure_url`, `table_url`, `download_url`) start
    with `config$base_url`, which is `public_url` on a shared server.
    They are not behind sign-in: whoever has the address has the file
    for a day. That is the rule for a tab's files too, but an agent's
    transcript is a likelier place for an address to leak from; decide
    whether that is acceptable for private projects or whether the files
    need a route that checks the token.
  - Per-user limits (step 10) matter more here, and so does the size of
    results: every `make_plot` result holds the image.
  - Apps that only speak the 2025 revisions cannot connect (Daniel's
    choice in step 9). If claude.ai or another app that matters has not
    moved by then, answering `initialize` as well is about 80 lines in
    `R/mcp.R` (`mcp_check_request()` is where the two eras part) and the
    specification describes it under "dual-era" servers.

- From step 10: what is ready for this step.
  - The proxy already passes `/mcp` unbuffered and uncompressed, and
    rate-limits `/oauth/` and `/.well-known/` by address (30 a minute,
    `ATIMA_LIMIT_OAUTH`). `/mcp` itself has no limit by address, on
    purpose; the per-account job limit (16, 429 as a tool result) is
    what holds an app back. `mcp` and `oauth` are reserved keys already.
  - Requests atima makes to other servers (a Client ID Metadata
    Document, a provider's token endpoint) should go through
    `waiting()` (`R/jobs.R`) with `httr2::req_perform_promise()`, as
    sign-in now does, so that a slow server holds up one caller only.
  - The privacy page (`inst/www/js/pages/privacy.js`) has a marked place
    for a paragraph saying that what a tool returns goes to the AI app's
    provider. `ai-apps.Rmd` and `server.Rmd` say shared servers do not
    offer `/mcp` yet; both need the new section.
  - `loadtest/loadtest.R` has an AI-app phase that only runs against a
    server without accounts (`--mode local`); with tokens it needs a way
    to get one.

Decisions for Daniel: whether this ships in the first release (if not, it
moves after step 14 and the status table says so); atima as its own
authorization server, or Globus; whether agents may explore public
projects without signing in; token lifetimes; whether signing out of the
browser also disconnects apps. For the tools that change data: whether
they are on by default on a local install and on the shared server; how a
file is uploaded; what "save" covers; whether share, publish, delete and
"new link" act at once or wait for the person's confirmation, and where
that confirmation happens; whether deleted projects are kept for a
period; whether an agent may search for users to share with.

## Step 12: Usage monitoring

An administrators' page on the shared server that answers two questions
with numbers that hold up in a grant application or a paper: how many
researchers use atima, from where, for what; and is the server still big
enough for them. This is not product analytics: no funnels, conversion or
revenue, and no following of individual people. Added by Daniel on
2026-11-13; it comes after steps 10 and 11 so that it covers the deployed
server (client addresses behind the proxy, the per-account job limit) and
both interfaces in both modes.

What the reading for this step turned up (check again when the step runs):

- Count people who did work, not page loads. Galaxy's public servers
  report "registered" and "active" users separately, where active means
  "ran at least one job in the period", next to jobs per month, countries
  reached and citing publications. Use the same definitions so the
  numbers can be compared, and print each definition on the page.
- No single number is trustworthy. Afiaz et al., "Evaluation of software
  impact designed for biomedical research" (2023, arXiv 2306.03255, from
  NCI's ITCR programme) recommend several measures side by side, stated
  transparently, and warn that a metric that is chased stops meaning
  anything. Show counts with what they leave out (bots, the lab's own
  use, load tests).
- Privacy-preserving counting is an established pattern (Plausible,
  GoatCounter, Swetrix and others): no cookie, no stored address;
  visitors without an account are told apart for one day by a hash of
  address, user agent and a secret that is replaced daily and never
  written to disk. The cost, to be stated on the page: such a visitor
  counts again on another day, so weekly and monthly "unique" numbers are
  only exact for people with an account (guests included, since a guest
  is a row in `users`).

What exists to build on, and what does not:

- `request_done()` (`R/router.R`) logs one `request` line per request
  with path, status, duration and user id, to stderr or a file. A log
  file is not something the server can chart from, and it has no
  function name, interface or waiting time. `users.seen_utc` records the
  last visit only.
- The job layer (`R/jobs.R`) does not record when a job was submitted,
  when a worker took it, or whether the answer came from the cache.
  Recording those is the main addition to the design.
- `/mcp` goes through the same router, and `initialize` carries the
  client's name (`clientInfo`), which tells Claude Code from other apps.
- The schema gives every function an `area` (`alpha`, `beta`, `taxa`,
  `rarefaction`) and a `use`, which is the grouping the charts need.

To build:

- Recording, in one place (the router and the job layer, never in
  handlers), into tables added by migration `inst/sql/007_<name>.sql`:
  - Actions: time, who (user id, or the daily hash for a visitor with no
    session), interface (`ui` or `mcp`, and the MCP client's name), kind
    (visit, plot, statistics, table, clusters, export, upload, save,
    share, publish, import), function and area, outcome (done, rejected
    argument, failed, replaced, cancelled, timed out, refused for load),
    time waiting for a worker, time running, cache hit. No argument
    values, field names, titles or anything else from a user's data.
  - Arrivals, once per visit: the referring host and path (query string
    dropped, atima's own pages ignored), read from the `Referer` header
    of the page request; country; and the network's organisation. Many
    sites send only their origin, so paths will be sparse.
  - Country and organisation come from the client address looked up in an
    offline database file the administrator supplies (the address is
    then discarded; nothing is sent to a lookup service). The
    organisation that owns the network is what makes "used at N
    institutions" countable, since universities and institutes mostly
    run their own networks. Behind the proxy this needs the forwarded
    address from a trusted header, which is step 10's configuration.
  - Capacity samples on a timer: workers busy, jobs waiting, and space
    used under `data_dir`.
  - Daily roll-ups, so raw rows can be deleted after a set time while
    the long charts survive. Distinct people per week, month and year
    cannot be added up from daily counts: keep one small row per person
    per active day, or compute the period counts at roll-up time.
  - Excluded from every count but kept visible as their own line:
    administrators, recognised bots and health checks, and load tests.
- The page (administrators only, declared in the route table like any
  other route), with a date range, every chart's data downloadable as
  CSV, and a "summary for a report" for a chosen period (a grant year)
  that gives the headline numbers with their definitions:
  - Reach: active users in the last 7, 30, 90 and 365 days and in total,
    beside registered accounts; active users per day, week and month
    over time; cumulative users over time; new against returning users
    per month.
  - Repeat use, which is what separates a tool people rely on from one
    they tried once: the share of each month's new users seen again in
    later months (a cohort table), and how many days each user was
    active in the last 90 (a histogram).
  - Where from: countries (ranked bars, and the count of countries);
    institutions or networks (ranked, and the count); referring sites
    and pages; sign-in provider.
  - What for: jobs per month stacked by area; functions ranked (which
    answers boxplot against corrplot); browser against MCP over time,
    and which MCP apps; datasets uploaded, projects analysed, exports,
    shares, published projects and legacy imports per month.
  - Capacity: median and 95th-percentile wait for a worker per day, with
    the share of jobs that waited more than 1 and more than 10 seconds;
    worker use and longest queue per hour; a weekday by hour-of-day heat
    map of load; requests refused for load (503, 429) and timed out
    (504); 95th-percentile run time per function; cache hit rate; disk
    use against capacity. One plain sentence at the top says whether the
    server is keeping up, by a stated rule (for example: the
    95th-percentile wait passed 5 seconds on more than 3 of the last 30
    days).
- Tests: every kind of action is recorded once and with the right
  interface; nothing from a request's arguments reaches the tables; the
  daily secret is not stored; roll-ups match the raw rows; the page and
  its data routes refuse everyone but administrators; the charts' data
  routes answer for an empty database. Run step 10's load test and check
  that the capacity charts show it.
- Docs: what is recorded and what is not, in words that can go into the
  site's privacy notice; how to supply the lookup file; and where the
  numbers this page cannot give come from (citations, CRAN or r-universe
  downloads, GitHub stars). Local installs are invisible by design.

- From step 10: for this step.
  - The visitor's address: Caddy sets `X-Real-IP` (and
    `X-Forwarded-For`) itself on every request and drops what the
    visitor sent; behind another proxy it takes that proxy's word only
    if `ATIMA_TRUSTED_PROXIES` names it. atima does not read either
    header yet: `request_client()` in `R/router.R` still records
    `REMOTE_ADDR`, which in the container is Caddy's address
    (`sessions.ip_address` holds it). Add a setting like
    `forwarded_proto_header` for the address header, and set it in
    `deploy/compose.yaml`.
  - Job timing exists per job: `j$queued_at` and `j$started_at` in
    `pool_submit()` and `pool_dispatch()`, and `data$timing` (queue and
    run time in ms) on every finished job, which the router already
    turns into the `Server-Timing` header. Record from there. Cache hits
    are still not known to the job layer.
  - Health checks arrive as `GET /api/health` every 30 seconds from the
    container itself and are logged like any request; exclude them. The
    load test's requests carry the user agent `atima-loadtest`.
  - Re-running the load test: `sh loadtest/run-series.sh "2" "30"` and
    `Rscript loadtest/summarise.R`; compare with the tables in
    `loadtest/README.md`.
  - The privacy page has a marked place, in "The server log", for what
    use is recorded. It already says that the network address of each
    open tab is stored, which is true of `sessions.ip_address`.
  - No proxy access log exists to fall back on, by decision.

Decisions for Daniel: whether anything is recorded in `auth = "none"`
(recommended: nothing, and no page; a local install must never report
use to anyone); which lookup database, given their licences (DB-IP Lite,
MaxMind GeoLite2), and whether institutions are taken from the network,
from the sign-in provider, or both; how long raw rows are kept; whether
visitors who never start a session are counted at all; how charts are
drawn with no chart library in the front end (hand-written SVG, one
small vendored library, or figures drawn in R); whether a public
"atima in numbers" page is wanted later, which would need small counts
hidden; and whether Baylor has rules on recording use of a public
research server that this must follow.

## Step 13: Interface refinement: compact controls, navigation

The front end from step 7 works, and Daniel approved its layout
(navigation left, figure in the middle, controls right). This step is
about how it looks and how much room it takes, not what it does. It
comes after steps 11 and 12 so that the pages they add (connected apps,
usage) are refined with the rest.

- The reference is the plot controls Daniel designed for the
  pre-renovation 5.0, the version kept in `cmmr/atima-old` (he calls it
  atima 4). Its code is in this repository's first commit
  (`git show ca1fd41:inst/www/modules/controls.js`, and beside it
  `dd.js`, `selz.js`, `layers.js`, `aes.js`, `checkbox.js`, `irs.js`,
  `md.js`, `taxa.js`, with `inst/www/style.css` and `js/page_plot.js`);
  step 7 deleted those files. Read them for how each kind of control was
  laid out and how much room it took, and rebuild that look in the
  current renderer: do not bring back the old code or its libraries
  (jQuery, selectize, ion-rangeSlider). That commit's `index.html` is
  the unwired mock-up, so the old interface cannot simply be run from
  it; ask Daniel for screenshots of the old plot page, or whether a
  server still runs it, to see it as he designed it. What not to
  resemble: atima 2's Shiny controls, a label on its own line above
  each full-width input, which is what step 7's controls look like now.
- The old controls are a guide, not a template (Daniel, 2026-11-14).
  They need not be copied exactly. The aim is controls that are compact,
  easy to use, and in which the control one is looking for is easy to
  find. For example, the old interface colored label text lime green
  for controls that pick metadata and gold for plot attributes; that
  color-coding may be kept, redone another way (grouping, icons,
  headings) or dropped, whichever serves finding a control best.
- Controls share their state between plot types, as the old interface
  did. If the user sets `stat.by = "Sex"` for `adiv_boxplot` and then
  goes to `taxa_boxplot`, it starts with `stat.by = "Sex"`. Today the
  store keeps arguments per function (`state.args[fn]`, `fnArgs()`,
  `setArg()`, `resetArgs()` in `inst/www/js/store.js`), so nothing
  carries over; read `js/page_plot.js` and `modules/controls.js` in
  commit `ca1fd41` for how the old interface did it. To settle in the
  design:
  - A value carries to another function only where it is valid there:
    the parameter exists in that function's schema, the value is among
    its choices (a metric that one plot offers and another does not, a
    layer name), and its `when` rule holds. What does not fit falls
    back to that function's default without an error, and comes back
    if the user returns to a plot where it fits.
  - Parameters of the same name do not always mean the same thing in
    every function; decide which are shared by name and which stay with
    their function, and keep that list in one place.
  - "Changed from the default", reset for one control and reset for the
    whole plot have to make sense with shared values: say what each
    resets. Only what the user changed is sent, as now.
  - Shared values still have to follow the project: `schema.js` already
    drops arguments that name a field or rank the open project lacks.
- Metadata fields and the look of their values (`color.by`, `stat.by`,
  `shape.by`, `pattern.by` and the like). Check first, against the
  installed rbiom 4 and its schema (`fn_schema()`, `/api/schema`, and
  rbiom's help), not from memory: for each plot function, which of
  these arguments exist, whether each may name a different field or one
  field drives them all, how the value-to-color, value-to-shape and
  value-to-pattern assignments are given (`colors`, `shapes`,
  `patterns`, or a list form of the `.by` argument), and whether one
  field's values can have a color, a shape and a pattern at the same
  time. Then see how the old interface presented it (`modules/aes.js`,
  `md.js`, `layers.js` in commit `ca1fd41`). Present what rbiom really
  allows:
  - If one field can control several of them, show that field once,
    with one row per value of the field and, in that row, the color,
    shape and pattern for that value, so the user sees the whole look
    of each group in one place.
  - If rbiom lets them differ, offer separate fields, but make the
    common case (one field for everything) the easy one, and never let
    the interface offer a combination rbiom refuses or ignores.
  - Record in this file what rbiom allows, per function, so that the
    answer is not worked out again. If rbiom's behaviour looks like a
    mistake, describe it for Daniel; rbiom is not changed from here.
- Compact plot controls:
  - A dropdown that is not open, with its label, takes one line: label
    on the left, current value on the right. The same for numbers,
    short text and switches. A control grows past one line only while
    it is open or when it holds several values (layers, a list of taxa,
    color assignments).
  - The marks a control carries today must survive in the smaller
    form: the dot for "changed from the default", reset, the help text
    (now a small icon beside the label), the reason a control is greyed
    out by a `when` rule, and messages for a rejected value.
  - Today's styles are in `inst/www/css/` (`.controls`, `.control`,
    `.control-head`, `.control-body`, `.control-pair`, `.toggles`), and
    the controls are built in one renderer from the schema, so this is
    mostly a change to that renderer's markup and the style sheet, with
    no change to what is sent to the server.
  - Long labels and long values (a metadata field's name comes from the
    user's file) are cut with an ellipsis and shown whole on hover and
    to screen readers; they never push a row onto two lines.
- A wide range of screens: decide the sizes to support and check each
  one, from a small laptop (about 1280 x 720, and narrower when the
  browser is not full screen) to a large desktop monitor, and at
  browser zoom of 125 and 150 percent. On a large screen the figure
  gets the space, not the controls. On a narrow one the controls and
  the navigation must still leave room for the figure: for example a
  navigation that folds to icons and a controls column that can be
  collapsed or moves under the figure. Whether phones and tablets are
  supported at all is Daniel's decision. No horizontal scrolling of the
  page at any supported size.
- Navigation labels: two links are much longer than the others,
  "Import from an older atima" and "Privacy and terms" (`buildNav()` in
  `inst/www/js/main.js`); the group names come from `areaLabels` in
  `js/schema.js` and the plot names from `shortLabel()`. Give every
  link a short label of about the same length (for example "Import"
  and "Privacy"), keep the longer wording as the page's heading and
  the link's tooltip, and check the labels step 11 and step 12 added.
- Keep what step 7 settled: no framework and no build step, one
  hand-written style sheet, nothing inline (the Content-Security-Policy
  forbids inline script and style), text from users inserted as text.
  Keyboard use and visible focus must still work on every control, and
  labels stay tied to their inputs.
- Tests and checks: the front-end tests still pass; add what can be
  tested without a browser (every nav label within a set length; no
  inline styles). Check in a browser at each supported size, with
  rbiom's example dataset and with one that has long field names and
  many fields, in both auth modes. Show Daniel screenshots or a running
  server of the plot page at the smallest and largest size before
  finishing, and again after his comments.

Decisions for Daniel: screenshots of the pre-renovation 5.0 plot page if
he has them, and which of its details to keep; how controls are told
apart now that the lime and gold labels are optional; which parameters
share their value between plot types; how a field and the look of its
values are presented, once rbiom has been checked; the screen sizes to support, and whether
phones and tablets are among them; what the page does when it is too
narrow for three columns; the new navigation labels; whether the
tables, dialogs and other pages get the same pass now or only the plot
controls and navigation.

## Step 14: Release

- Version, NEWS, citation, DOI.
- CRAN or r-universe submission. Remove `Remotes: cmmr/rbiom` from
  `DESCRIPTION` once rbiom 4 is on CRAN (it was 3.1.0 on 2026-11-10), and
  update the install instructions in `README.md` and the comment in the CI
  workflow.
- From step 7: the package ships three third-party libraries under
  `inst/www/assets` (Font Awesome Free, highlight.js, DOMPurify), listed
  with their licences in `inst/www/assets/LICENSES.md`. CRAN expects
  their authors in `Authors@R` (role `ctb` or `cph`) and usually an
  `inst/COPYRIGHTS` file; `DESCRIPTION` names neither yet. The pictures
  under `inst/www/img` (`gallery/`, `AdrienSaraLogo.png`) include files
  the app does not use; decide which to ship.
- From step 8: the package now exports two functions, `run()` and
  `legacy_convert()`, and suggests `bcrypt` and `RMariaDB`. Decide
  whether the legacy import ships in the CRAN release or is removed once
  the lab's users have moved; it is self-contained (`R/legacy*.R`,
  `inst/sql/006_legacy.sql`, three routes, one page, one `CONF` field).
- From step 9: `DESCRIPTION`'s text and the README's opening still
  describe a web interface only; say that the package is also an MCP
  server. NEWS should name the MCP revision (2026-07-28) the release
  speaks. `jsonvalidate` is a new Suggests (tests only); it needs V8,
  which CRAN's machines have. Check before release that the revision is
  still current, and that the apps named in the README still connect.
- From step 10: before release.
  - Daniel has to read the privacy and terms text
    (`inst/www/js/pages/privacy.js`); its last two "Terms of use" lines
    are legal statements. Its header comment says "Draft".
  - The app's shell shows the Baylor College of Medicine logo and the
    home page the CMMR logo (`inst/www/img/BCM_120px.png`, `CMMR.png`)
    on every server, including other labs'. Decide whether they ship.
  - `projects.editors` (the creator's name, possibly "Guest 12") is sent
    to every visitor for public projects (`info.editors` in the tree);
    the interface does not show it. The privacy page says so; consider
    not sending it.
  - There is no way to delete an account; the privacy page tells people
    to contact the operator, who has no tool for it either.
  - `sign-in.Rmd` and `server.Rmd` say what has not been tested against
    a real provider and a real server; remove those sentences when it
    has been.
  - The pkgdown workflow deletes `RENOVATION.md` from its checkout before
    building (pkgdown makes a page of every top-level Markdown file);
    drop that step when this file goes. `DESCRIPTION` still says nothing
    of the site's articles or of the MCP server.
  - `loadtest/` and `deploy/` are in `.Rbuildignore`; they ship with the
    repository, not the package.
  - Stale notes above, left as history: step 7's "there is still no
    route to create, rename or delete public collections", step 5's
    `CONF` field list and its choice (e), and step 10's note that imports
    are not counted by the job limit.
- Delete this file.
