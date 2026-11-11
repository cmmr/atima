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

The package has one exported function:

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
