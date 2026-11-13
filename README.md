# atima

**Agile Toolkit for Incisive Microbiome Analyses**

<!-- badges: start -->
[![R-CMD-check](https://github.com/cmmr/atima/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/cmmr/atima/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

atima is an R package that serves a web interface for the
[rbiom](https://github.com/cmmr/rbiom) microbiome package. Users upload BIOM
files and explore alpha diversity, beta diversity and taxa abundance plots in
their browser. Projects are stored in an SQLite database on the machine
running the server.

> **Status: under renovation.** atima 5 is being rebuilt and is not ready for
> use. The R back end starts and answers API requests, but the web interface
> in this repository is a partly connected redesign, and the account and
> deployment code is about to be replaced. Do not expose it to a network.


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


## Configuration

Each setting can be given as an argument to `run()`, as an environment
variable, or as an R option. They are looked up in that order, and the
default is used if none is set.

| Argument        | Env. variable         | R option              | Default                               | Purpose                                              |
|-----------------|-----------------------|-----------------------|---------------------------------------|------------------------------------------------------|
| `port`          | `ATIMA_PORT`          | `atima.port`          | `8080`                                | Port to listen on.                                   |
| `host`          | `ATIMA_HOST`          | `atima.host`          | `"127.0.0.1"`                         | Address to listen on. The default accepts connections from this computer only. |
| `data_dir`      | `ATIMA_DATA_DIR`      | `atima.data_dir`      | `tools::R_user_dir("atima", "data")`  | Database, stored BIOM files and cache.               |
| `temp_dir`      | `ATIMA_TEMP_DIR`      | `atima.temp_dir`      | a new directory under `tempdir()`     | Temporary files, figures and exports. Must be outside `data_dir`; old files here are deleted. |
| `workers`       | `ATIMA_WORKERS`       | `atima.workers`       | half the CPU cores, 1 to 4            | Worker processes. Each runs one job (a plot, an upload, an export) at a time. |
| `max_cpus`      | `ATIMA_MAX_CPUS`      | `atima.max_cpus`      | CPU cores divided by `workers`        | CPU cores one job may use.                           |
| `time_limit`    | `ATIMA_TIME_LIMIT`    | `atima.time_limit`    | `60`                                  | Longest a job may run, in seconds.                   |
| `cache_size_mb` | `ATIMA_CACHE_SIZE_MB` | `atima.cache_size_mb` | `100`                                 | Upper limit for the cache of computed results, in MB. |
| `max_upload_mb` | `ATIMA_MAX_UPLOAD_MB` | `atima.max_upload_mb` | `50`                                  | Largest upload accepted, in MB.                      |
| `session_hours` | `ATIMA_SESSION_HOURS` | `atima.session_hours` | `24`                                  | A browser tab not heard from for this long loses its session, unsaved changes and temporary files. |
| `guest_days`    | `ATIMA_GUEST_DAYS`    | `atima.guest_days`    | `30`                                  | A guest who has not visited for this long is forgotten, with the projects only they could open. |
| `legacy`        | `ATIMA_LEGACY`        | `atima.legacy`        | none                                  | Older installations to import from; see "Importing from an older atima". |
| `open`          | `ATIMA_OPEN`          | `atima.open`          | `interactive()`                       | Open a browser once the server is up.                |

The R session that calls `run()` answers requests and owns the database.
Everything that reads a BIOM file or calls rbiom runs in the worker
processes, so the server keeps answering while a plot is drawn. With
`workers = 1`, jobs run one after another, which suits a single user on a
laptop. A job that runs past `time_limit` is stopped. When the server is
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

See `?atima::run` for details.

### Importing from an older atima

atima 2 (the Shiny application with a MariaDB or MySQL database) encrypted
every project with keys that only its users' passwords unlock. Its data can
therefore not be moved by an administrator alone. Instead, the administrator
saves the old database once, and each person brings their own projects over
by typing the email address and password they had on the old site.

**1. Save the old database.** On a computer that can reach it, with the
`RMariaDB` package installed, run this once. A database account that may
only `SELECT` is enough, and the old database is not changed.

```r
con <- DBI::dbConnect(
  RMariaDB::MariaDB(),
  dbname = "atima", host = "<database host>",
  user = "<user>", password = Sys.getenv("ATIMA2_DB_PASSWORD") )

atima::legacy_convert(con, "atima2.sqlite")
DBI::dbDisconnect(con)
```

If all you have is a `mysqldump` file, restore it into any MariaDB server
first (the tables needed are `Users`, `Projects`, `Permissions` and
`Objects`) and connect to that.

The result is one SQLite file. It holds, for each account, the email
address, the bcrypt hash of the password and the encrypted private key, and
for each project that was not deleted, who could open it and its data, still
encrypted as atima 2 stored it. Names, affiliations, sessions, sign-in
tokens and cached results are not copied. Treat the file as you would the
old database: keep it out of version control and readable only by the
account the server runs as. After this the old database server is no longer
needed.

**2. Register the file.** Install the `bcrypt` package on the server
(`install.packages("bcrypt")`), and name the file, with the label people
should see, when starting it:

```r
atima::run(
  auth   = "oidc",
  legacy = c("ATIMA 2 (2019 to 2026)" = "/srv/atima/atima2.sqlite") )
```

or `ATIMA_LEGACY="ATIMA 2 (2019 to 2026)=/srv/atima/atima2.sqlite"`; several
entries are separated by `;`. The server only reads the file, and refuses to
start if it is missing, was not made by `legacy_convert()`, or `bcrypt` is
not installed.

**3. What people do.** Someone who is signed in finds "Import from an older
atima" in the menu, enters their old email address and password, and ticks
the projects to import. What to know:

- The old password is checked, and the projects are decrypted, in memory in
  a worker process. The password and the keys it unlocks are never written
  to the database, the log or a file.
- A project is imported once. If someone else who could open it on the old
  site imports it later, they are given the same project, with the access
  they had there (editor or viewer), so sharing carries over as people
  arrive. Someone who could only view a project can only view it here; if
  they are the first to import it, it has no editor until one imports it.
- Public example projects of the old site are not offered; only their
  editors can import them.
- After five wrong passwords, a person, and separately the old account they
  tried, must wait 15 minutes.
- A person who has forgotten their old password cannot import: nobody,
  including the administrator, can decrypt their projects without it.
- When everyone has moved, remove the `legacy` setting and delete the file.


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
