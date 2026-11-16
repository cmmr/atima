# atima

**Agile Toolkit for Incisive Microbiome Analyses**

<!-- badges: start -->
[![R-CMD-check](https://github.com/cmmr/atima/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/cmmr/atima/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

atima is an R package that serves a web interface for the
[rbiom](https://github.com/cmmr/rbiom) microbiome package. Users upload their
counts (a BIOM file, QIIME 2 or mothur output, or a plain table; see
[What you can upload](#what-you-can-upload)) and explore alpha diversity,
beta diversity and taxa abundance plots in their browser. Projects are stored in an SQLite database on the machine
running the server.

> atima 5 is a pre-release: it has not been released yet, and details may
> still change.

Documentation: <https://cmmr.github.io/atima/>

- [Using atima on your own computer](https://cmmr.github.io/atima/articles/local-install.html)
- [Running a shared server](https://cmmr.github.io/atima/articles/server.html)
- [Setting up sign-in (OpenID Connect)](https://cmmr.github.io/atima/articles/sign-in.html)
- [Importing from an older atima](https://cmmr.github.io/atima/articles/legacy-import.html)
- [Connecting an AI app](https://cmmr.github.io/atima/articles/ai-apps.html)
- [Where your data goes (local use)](https://cmmr.github.io/atima/articles/data-handling.html)


## Installation

atima needs R 4.3 or later and rbiom 4.0.0 or later. rbiom 4 is not on CRAN
yet, so both are installed from GitHub:

```r
# install.packages("pak")
pak::pak("cmmr/atima")
```

[Pandoc](https://pandoc.org/installing.html) must also be installed; it is
used to convert project descriptions. RStudio ships with a copy.


## Usage

The server is one function:

```r
atima::run()
```

This starts the server on <http://127.0.0.1:8080>, opens it in a browser when
R is interactive, and blocks the R session until it is interrupted. On first
start it creates the data directory and loads two example projects from rbiom
(`hmp50` and `gems`).


## What you can upload

A project starts from one file of counts. The rest can be in that file or
be added afterwards, one part at a time. rbiom reads the files and tells
them apart by their content, so the file's name does not matter, and a file
compressed with gzip or bzip2 is read as it is.

| Part | Files |
|------|-------|
| A new project (counts) | A BIOM file, version 1.0 (JSON) or 2.1 (HDF5), with whatever metadata, taxonomy and tree it holds. A QIIME 2 feature table (`.qza`). A mothur `.shared` file with one label. A table as tab- or comma-separated text: taxa in rows, samples in columns, and optionally a `taxonomy` column of lineages (`Bacteria; Firmicutes; ...`). |
| Sample metadata | A table as CSV or tab-separated text (or Excel, where the `readxl` package is installed), with the sample names in the first column. QIIME 2's metadata files are such tables. |
| Taxonomy | A table with the taxon names in the first column, and a column for each rank or one column of lineages. A QIIME 2 taxonomy artifact (`.qza`). A mothur `.cons.taxonomy` file. |
| Phylogenetic tree | A Newick file, or a QIIME 2 phylogeny artifact (`.qza`). It needs a tip for every taxon of the project; other tips are left out. |

Samples that new metadata does not list, and taxa that a new taxonomy does
not list, leave the project; atima says which. Counts that are not whole
numbers (relative abundances) can be scaled up to whole numbers, after a
warning about what that costs. A file that cannot be read is refused with
the reason: sample names that do not match, tree tips that do not match,
decimal commas, an Excel workbook where text is needed, a QIIME 2 artifact
of another kind. A BIOM file whose tree does not match its counts becomes a
project without a tree.

The largest file accepted is 50 MB unless `max_upload_mb` says otherwise.
The app has two small files to start from, counts and metadata, beside its
upload button.


## Configuration

Each setting can be given as an argument to `run()`, as an environment
variable, or as an R option. They are looked up in that order, and the
default is used if none is set.

| Argument | Env. variable | Default | Purpose |
|----------|---------------|---------|---------|
| `port` | `ATIMA_PORT` | `8080` | Port to listen on. |
| `host` | `ATIMA_HOST` | `"127.0.0.1"` | Address to listen on. The default accepts connections from this computer only; `"0.0.0.0"` needs `auth = "oidc"`. |
| `auth` | `ATIMA_AUTH` | `"none"` | Who may use the server: `"none"` for one person on their own computer, `"oidc"` for a shared server with sign-in. |
| `public_url` | `ATIMA_PUBLIC_URL` | `http://localhost:<port>` on this computer, otherwise required | With `auth = "oidc"`: the address people type to reach the server, such as `https://atima.example.org`. |
| `oidc_issuer` | `ATIMA_OIDC_ISSUER` | `"https://auth.globus.org"` | The sign-in provider's issuer URL. For ORCID, `"https://orcid.org"`. |
| `oidc_client_id` | `ATIMA_OIDC_CLIENT_ID` | none | The client id the provider gave you. |
| `oidc_client_secret` | `ATIMA_OIDC_CLIENT_SECRET` | none | The client secret the provider gave you. Set it in the environment, not in a script. |
| `admins` | `ATIMA_ADMINS` | none | The provider's identifiers (`sub`) of the administrators, separated by commas. |
| `forwarded_proto_header` | `ATIMA_FORWARDED_PROTO_HEADER` | none | A header in which your reverse proxy says whether the visitor used HTTPS. Not needed when `public_url` starts with `https://`. |
| `client_ip_header` | `ATIMA_CLIENT_IP_HEADER` | none | A header in which your reverse proxy states the visitor's network address, such as `X-Real-IP`. Without it, every visitor behind a proxy has the proxy's address. |
| `signin_days` | `ATIMA_SIGNIN_DAYS` | `30` | How long a sign-in lasts, in days. |
| `operator` | `ATIMA_OPERATOR` | none | With `auth = "oidc"`: who runs the server, shown on the app's "Privacy and terms" page. |
| `contact` | `ATIMA_CONTACT` | none | With `auth = "oidc"`: an email address or `https://` page for reaching whoever runs the server. |
| `data_dir` | `ATIMA_DATA_DIR` | `tools::R_user_dir("atima", "data")` | Database, stored BIOM files and cache. |
| `temp_dir` | `ATIMA_TEMP_DIR` | a new directory under `tempdir()` | Temporary files, figures and exports. Must be outside `data_dir`; old files here are deleted. |
| `cpus` | `ATIMA_CPUS` | every CPU core | The most CPU cores the server may use: the process that answers requests and the worker processes that run jobs (plots, uploads, exports) together. |
| `time_limit` | `ATIMA_TIME_LIMIT` | none with `auth = "none"`, `60` with `auth = "oidc"` | Longest a job may run, in seconds. |
| `jobs_per_user` | `ATIMA_JOBS_PER_USER` | `16` | With `auth = "oidc"`: the most jobs one person or guest may have waiting or running at once. |
| `cache_size_mb` | `ATIMA_CACHE_SIZE_MB` | `100` | Upper limit for the cache of computed results, in MB. |
| `max_upload_mb` | `ATIMA_MAX_UPLOAD_MB` | `50` | Largest upload accepted, in MB. |
| `session_hours` | `ATIMA_SESSION_HOURS` | `24` | A browser tab not heard from for this long loses its session, unsaved changes and temporary files. |
| `guest_days` | `ATIMA_GUEST_DAYS` | `30` | A guest who has not visited for this long is forgotten, with the projects only they could open. |
| `trash_days` | `ATIMA_TRASH_DAYS` | `30` | A deleted project is kept this long, and can be restored by its editors, before it is erased. |
| `mcp_writes` | `ATIMA_MCP_WRITES` | `TRUE` | May AI apps change data (upload, edit, copy, share, publish, delete)? `FALSE` offers them reading and analysing only. |
| `app_days` | `ATIMA_APP_DAYS` | `30` | With `auth = "oidc"`: a connected AI app stays connected until it has not been used for this long. |
| `app_changes_per_hour` | `ATIMA_APP_CHANGES_PER_HOUR` | `60` | The most changes one connected AI app may make in an hour. |
| `usage` | `ATIMA_USAGE` | `TRUE` | With `auth = "oidc"`: record how the server is used, for the administrators' "Usage" page; see "Usage of a shared server". A local install never records anything. |
| `usage_months` | `ATIMA_USAGE_MONTHS` | `25` | How long the record of single actions and visits is kept, in months. The daily counts made from it are kept. |
| `geo_db` | `ATIMA_GEO_DB` | none | Files (`.mmdb`, separated by `;`) in which a visitor's country and network owner are looked up for the Usage page. |
| `legacy` | `ATIMA_LEGACY` | none | Older installations to import from; see "Importing from an older atima". |
| `open` | `ATIMA_OPEN` | `interactive()` | Open a browser once the server is up. |

The R option for a setting is `atima.<argument>`, for example
`options(atima.port = 8081)`.

The R session that calls `run()` answers requests and owns the database.
Everything that reads a BIOM file or calls rbiom runs in the worker
processes, so the server keeps answering while a plot is drawn. One of
the `cpus` cores is kept for the process that answers requests, and there
is a worker process for each of the others (but no more than one for
every 2 GB of memory), so with `cpus = 8` seven jobs run at the same time.
Most of rbiom runs on one core. A job that computes distances between
samples (the beta diversity functions) is told it may use the cores that
are free when it starts; atima then measures what each worker really
uses, four times a second, and gives the cores a job has stopped using to
the next one. A job that runs past `time_limit` is stopped; a local install has
no time limit unless you set one, so an analysis that a shared server stops
can be run to its end on your own computer. When the server is
interrupted it cancels running jobs, stops the workers and closes the
database.

### Who can use it

By default (`auth = "none"`) atima is for one person on their own computer.
There are no accounts, the server only listens on `127.0.0.1`, and it
refuses to start on an address that other computers can reach.

For a shared server, use `auth = "oidc"`. People then sign in through an
OpenID Connect provider such as [Globus Auth](https://www.globus.org/platform/services/auth)
(the default) or [ORCID](https://orcid.org); atima stores no passwords.
Register the server with the provider as a web application whose redirect
URL is `<public_url>/auth/callback`, then start it with the client id and
secret the provider gave you, preferably from the environment:

```sh
export ATIMA_OIDC_CLIENT_ID="<client id>"
export ATIMA_OIDC_CLIENT_SECRET="<client secret>"
```

```r
atima::run(
  host       = "0.0.0.0",
  auth       = "oidc",
  public_url = "https://atima.example.org" )
```

Put a reverse proxy in front for HTTPS. Visitors who have not signed in can
explore public projects and upload their own data, which is kept for
`guest_days` and becomes theirs when they sign in.

[Setting up sign-in](https://cmmr.github.io/atima/articles/sign-in.html) has the steps for Globus Auth and
ORCID, and [Running a shared server](https://cmmr.github.io/atima/articles/server.html) covers HTTPS,
containers and backups. See `?atima::run` for every setting.

### Usage of a shared server

A server with sign-in keeps count of how it is used, so that whoever runs
it can say how many researchers it serves and can tell when it is outgrown.
Its administrators find a page, "Usage", under "About": active users per
day, week and month, new and returning users, the countries and
institutions they come from and the sites that link to the server, which
analyses are run, in the browser and through AI apps, and how long jobs
wait for a worker. Every chart's numbers download as CSV, and the page
writes a summary of a chosen period for a report.

What is recorded is counts, not content: for each action the time, the
number that stands for the user, the kind of action, the name of the rbiom
function, how it ended and how long it took. No network address, name,
email address, project or setting is recorded, no cookie is set for it, and
nothing is sent anywhere. The country and the owner of a visitor's network
are looked up in files on the server itself, which you supply with
`geo_db`; [DB-IP's free Lite databases](https://db-ip.com/db/lite.php)
(Creative Commons Attribution 4.0) work. The app's "Privacy and terms" page
tells the people who use the server all of this. `usage = FALSE` switches
it off.

A local install (`auth = "none"`) records nothing and reports nothing to
anyone, so people who run atima on their own computer are not in any
count.

### Importing from an older atima

atima 2 (the Shiny application with a MariaDB or MySQL database) encrypted
every project with keys that only its users' passwords unlock. Its data can
therefore not be moved by an administrator alone. Instead, the administrator
saves the old database to a file once with `atima::legacy_convert()` and
names the file in the `legacy` setting (this needs the `bcrypt` package).
Each person who is signed in then finds "Import from an older atima" in the
menu, types the email address and password they had on the old site, and
chooses the projects to bring over. A person who has forgotten their old
password cannot import: nobody, including the administrator, can decrypt
their projects without it.

```r
# Once. `con` is a DBI connection to the old database.
atima::legacy_convert(con, "atima2.sqlite")

atima::run(
  auth   = "oidc",
  legacy = c("ATIMA 2 (2019 to 2026)" = "/srv/atima/atima2.sqlite") )
```

The file is as sensitive as the old database. See
[Importing from an older atima](https://cmmr.github.io/atima/articles/legacy-import.html) for the steps, what
comes over, and what to watch for.


## Using atima from an AI app

atima is also a
[Model Context Protocol](https://modelcontextprotocol.io) (MCP) server, so
an AI app that speaks MCP can explore your projects, run statistics and
make figures when you ask it to, and, if you allow it, upload files and
change, copy, share, publish and delete projects. The endpoint is the
server's address followed by `/mcp`; `run()` prints it when it starts.
With [Claude Code](https://claude.com/claude-code), for example:

```sh
claude mcp add --transport http atima http://127.0.0.1:8080/mcp
```

Then ask in plain words: "List my atima projects", "Draw an ordination of
hmp50 colored by body site". What to know:

- A local atima (`auth = "none"`) lets in any app on the computer that is
  given the address, as you. On a shared server (`auth = "oidc"`) each
  person signs in and approves an app, and chooses whether it may only
  read or may also change things.
- The app is given six tools that read and compute and, unless
  `mcp_writes` is `FALSE`, tools that change data. Sharing, publishing
  and deleting act only when the app confirms them; a deleted project can
  be restored for `trash_days`; every change an app makes is listed on
  the "Connected apps" page; and one app can make
  `app_changes_per_hour` changes an hour.
- **Your data goes where the app sends it.** What a tool returns
  (metadata values, statistics, figures) is handed to the AI app, and
  most apps send it on to their provider's servers. If the data must stay
  where it is, use an app that runs its model locally, or do not connect
  one.
- atima speaks revision 2026-07-28 of the MCP specification, and also
  answers apps that only know the revisions of 2025.

See [Connecting an AI app](https://cmmr.github.io/atima/articles/ai-apps.html) for the tools, limits and
troubleshooting, and [Where your data goes](https://cmmr.github.io/atima/articles/data-handling.html) for what
a local atima stores and sends.


## Development

```r
devtools::load_all()
devtools::test()
devtools::check()
```

`NAMESPACE` and `man/` are generated by roxygen2; run `devtools::document()`
after changing roxygen comments. Internal functions are tagged `@noRd`.


## License

MIT. See [LICENSE.md](LICENSE.md).
