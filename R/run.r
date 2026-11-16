#______________________________________________________________________________
#' Run the atima server
#'
#' Starts a web server that lets users upload their counts (a BIOM file,
#' QIIME 2 or mothur output, or a plain table) and explore them
#' with 'rbiom' plots in their browser. Projects are stored in an SQLite
#' database and a set of files under `data_dir`.
#'
#' The R session that calls `run()` answers requests and owns the database.
#' Everything that reads a BIOM file or calls 'rbiom' is done by a pool of
#' worker processes, so the server keeps answering while a plot is drawn.
#' See the section on jobs for how many there are.
#'
#' Every argument can also be set with an environment variable or an R
#' option. The first of these that is set is used:
#' \enumerate{
#'   \item the argument itself, e.g. `run(port = 8080)`
#'   \item the environment variable `ATIMA_<NAME>`, e.g. `ATIMA_PORT=8080`
#'   \item the R option `atima.<name>`, e.g. `options(atima.port = 8080)`
#'   \item the default shown below
#' }
#'
#' @param port        Port to listen on.
#' @param host        IP address to listen on. The default, `"127.0.0.1"`,
#'                    only accepts connections from this computer. Use
#'                    `"0.0.0.0"` to listen on all interfaces; that needs
#'                    `auth = "oidc"`.
#' @param auth        Who may use the server. `"none"`, the default, is for
#'                    one person on their own computer: there are no
#'                    accounts and nothing to sign in to, and `host` must be
#'                    a loopback address. `"oidc"` is for a shared server:
#'                    visitors sign in through an OpenID Connect provider.
#'                    See the section on signing in.
#' @param public_url  With `auth = "oidc"`: the address people type to reach
#'                    the server, such as `"https://atima.example.org"`.
#'                    Needed unless the server is only used from this
#'                    computer, when it defaults to `http://localhost:<port>`.
#' @param oidc_issuer  The OpenID Connect provider's issuer URL. The default
#'                    is Globus Auth; for ORCID use `"https://orcid.org"`.
#' @param oidc_client_id,oidc_client_secret  The client id and secret that
#'                    the provider gave you when you registered this
#'                    server with it. Prefer the environment variables
#'                    `ATIMA_OIDC_CLIENT_ID` and `ATIMA_OIDC_CLIENT_SECRET`
#'                    to writing the secret in a script.
#' @param admins      With `auth = "oidc"`: the provider's identifiers
#'                    (`sub` claims) of the people who are administrators,
#'                    as a character vector or one comma-separated string.
#'                    Administrators can change public projects. The
#'                    default, `NULL`, leaves administrators as they are in
#'                    the database.
#' @param forwarded_proto_header  The name of a request header, set by a
#'                    reverse proxy you control, that says whether the
#'                    visitor used HTTPS; usually `"X-Forwarded-Proto"`. The
#'                    default, `NULL`, trusts no such header. Not needed
#'                    when `public_url` starts with `https://`.
#' @param client_ip_header  The name of a request header, set by a reverse
#'                    proxy you control, that holds the visitor's network
#'                    address; `"X-Real-IP"` or `"X-Forwarded-For"`. If it
#'                    lists several addresses, the last is used: the one the
#'                    proxy itself added. The default, `NULL`, uses the
#'                    address of the connection, which behind a proxy is the
#'                    proxy's.
#' @param signin_days  How long a sign-in lasts before the browser has to
#'                    sign in again.
#' @param operator    With `auth = "oidc"`: who runs this server, as the
#'                    words to finish the sentence "This server is run by
#'                    ...", such as `"the Example Lab at Example University"`.
#'                    Shown on the app's "Privacy and terms" page. The
#'                    default, `NULL`, leaves that sentence out.
#' @param contact     With `auth = "oidc"`: how the people who use the server
#'                    can reach whoever runs it: an email address, or the
#'                    `https://` address of a page. Shown on the same page.
#' @param data_dir    Directory for the database and stored BIOM files. It
#'                    is created, and filled with two example projects, the
#'                    first time the server starts.
#' @param temp_dir    Directory for temporary files, including the figures
#'                    and exports that browsers download. It must not be
#'                    `data_dir`, or inside it: old files here are deleted.
#' @param cpus        The most CPU cores the server may use: the process
#'                    that answers requests and the worker processes that
#'                    run jobs (plots, uploads, exports, ...) together. The
#'                    default is every core available. With `cpus = 1` or
#'                    `2`, jobs run one after another. See the section on
#'                    jobs.
#' @param time_limit  The longest a job may run, in seconds. A job that
#'                    takes longer is stopped and the user is told so. The
#'                    default, `NULL`, is no limit with `auth = "none"`,
#'                    where the computer is the user's own, and 60 seconds
#'                    with `auth = "oidc"`, where the limit keeps one
#'                    person's long analysis from holding up everyone else.
#' @param jobs_per_user  With `auth = "oidc"`: the most jobs one person (or
#'                    one guest) may have waiting or running at the same
#'                    time. See the section on jobs.
#' @param cache_size_mb  Upper limit, in megabytes, for the cache of
#'                    computed results kept in `data_dir`. Half is for
#'                    atima's own cache and half for rbiom's.
#' @param session_hours  A session is closed, and its unsaved changes and
#'                    temporary files are deleted, when its browser tab has
#'                    not been heard from for this many hours.
#' @param guest_days  A guest (someone who has not signed in) is forgotten
#'                    after this many days without a visit, along with any
#'                    projects that only they could open.
#' @param max_upload_mb  Largest upload to accept, in megabytes.
#' @param trash_days  A deleted project is kept for this many days, during
#'                    which its editors can restore it, and is then erased.
#' @param mcp_writes  May AI apps change data: upload, edit, copy, share,
#'                    publish and delete projects? `FALSE` offers them only
#'                    the tools that read and compute. See the section on
#'                    AI apps.
#' @param app_days    With `auth = "oidc"`: an AI app that a person has
#'                    connected stays connected until it has not been used
#'                    for this many days.
#' @param app_changes_per_hour  The most changes one connected AI app may
#'                    make in an hour.
#' @param usage       With `auth = "oidc"`: record how the server is used,
#'                    for the administrators' "Usage" page? See the section
#'                    on usage. A local install never records anything.
#' @param usage_months  How many months the record of single actions and
#'                    visits is kept. The daily counts made from it are kept.
#' @param geo_db      With `usage`: one or more files in MaxMind DB format
#'                    (`.mmdb`) in which the country and the owner of a
#'                    visitor's network are looked up, such as DB-IP's free
#'                    "IP to Country Lite" and "IP to ASN Lite". A character
#'                    vector, or one string with the paths separated by `;`.
#'                    The default, `NULL`, records neither.
#' @param legacy      Older atima installations whose users may import
#'                    their projects: a named character vector,
#'                    `c(<label shown to users> = <file>)`, of files made by
#'                    [legacy_convert()]. As an environment variable,
#'                    `<label>=<file>` entries separated by `;`. See the
#'                    section "Importing from an older atima".
#' @param open        Open the app in a web browser once the server is up?
#'
#' @section Signing in:
#' With `auth = "none"` there is nothing to set up. The server refuses to
#' start on an address other computers can reach, and only answers requests
#' addressed to `localhost`, `127.0.0.1` or `[::1]`. Everything belongs to
#' one local user, including projects that guests or password accounts
#' made with an earlier version of atima. Anyone who can use this computer
#' while the server runs can open the app.
#'
#' With `auth = "oidc"` atima keeps no passwords. Register the server with
#' the provider as a web application (a confidential client) whose redirect
#' URL is `<public_url>/auth/callback`, and give `run()` the client id and
#' secret. atima reads everything else from the provider's discovery
#' document and uses the authorization code flow with PKCE. A person is
#' recognised by the provider's identifier for them, never by their email
#' address. Visitors who have not signed in are guests: they can explore
#' public projects, and what they upload is kept for `guest_days` and
#' becomes theirs when they sign in.
#'
#' The browser is recognised by one cookie. It cannot be read by scripts,
#' is not sent with requests made by other sites, and is marked `Secure`
#' whenever the site is served over HTTPS (see `public_url` and
#' `forwarded_proto_header`). Serve a public server over HTTPS, through a
#' reverse proxy.
#'
#' @section Privacy and terms:
#' With `auth = "oidc"` the app has a page, "Privacy and terms", linked from
#' the menu and from beside the sign-in button. Its text ships with the
#' package and describes what the software does: what it stores and for how
#' long (using this server's `guest_days` and `session_hours`), who can see
#' a project, that public projects are not reviewed, and that the service
#' comes without warranty. Set `operator` and `contact` so that it also says
#' who runs the server and how to reach them. It is a description of the
#' software, not legal advice: if your institution needs its own terms, link
#' to them from `contact`.
#'
#' @section Usage:
#' A shared server (`auth = "oidc"`) keeps a record of how it is used, and
#' its administrators find a page, "Usage", in the menu: how many people
#' used the server over time and how many came back, the countries and
#' institutions they came from and the sites that sent them, which analyses
#' they ran, through the browser or an AI app, and whether jobs had to
#' wait for a worker. The page's numbers can be downloaded as CSV files and
#' summed up for a period, for a grant report. `usage = FALSE` switches the
#' recording and the page off.
#'
#' What is recorded is a row per action: the time, the number that stands
#' for the user, the kind of action, the name of the 'rbiom' function, how
#' it ended and how long it took. No network address, name or email address
#' is recorded, and nothing of a project or of a request's settings. For a
#' visit, the site the browser was sent from is recorded, and, if `geo_db`
#' names lookup files, the country and the owner of the network it came
#' from; the address is looked up in those files on this server and is not
#' kept with the record. Requests that carry no cookie (crawlers, scripts)
#' are counted by a hash of address and user agent that changes every day
#' and cannot be turned back into an address. No cookie is set for any of
#' this. The app's "Privacy and terms" page says all of it to the people
#' who use the server.
#'
#' The lookup files are not part of atima. DB-IP publishes free ones
#' monthly at <https://db-ip.com/db/lite.php> under the Creative Commons
#' Attribution 4.0 licence, which asks for a link to db-ip.com where the
#' data is used; the Usage page carries one. Behind a reverse proxy, set
#' `client_ip_header`, or every visitor has the proxy's address.
#'
#' With `auth = "none"` nothing is recorded, there is no such page, and
#' atima never reports use to anyone.
#'
#' @section Importing from an older atima:
#' atima 2 kept every project encrypted with keys that only its users'
#' passwords unlock, so its data cannot be moved by an administrator alone.
#' Instead, save the old database to a file once with [legacy_convert()],
#' and name the file in `legacy`. Someone who is signed in (or, with
#' `auth = "none"`, the local user) then finds "Import from an older atima"
#' in the menu, types the email address and password they used on the old
#' site, and chooses the projects to bring over. They are imported in the
#' background, one at a time, while the person keeps working. The password
#' is checked and the projects are decrypted in memory; the server holds
#' the password only while that person's import runs, and neither it nor
#' any key is stored or logged. A project is imported once: when someone else
#' who could open it on the old site imports it later, they are given the
#' same project with the access they had (editor or viewer). After five
#' wrong passwords a person, and the old account they tried, must wait 15
#' minutes. This needs the 'bcrypt' package.
#'
#' @section AI apps:
#' The server is also a Model Context Protocol (MCP) server, at the path
#' `/mcp` (for example `http://127.0.0.1:8080/mcp`). An AI app that is given
#' that address can list and describe a person's projects, run 'rbiom'
#' statistics, draw plots and export data. Unless `mcp_writes` is `FALSE`,
#' it can also upload files, change, copy, share, publish and delete
#' projects, as that person can in the browser. Every change an app makes
#' is recorded and shown on the app's "Connected apps" page, one app may
#' make `app_changes_per_hour` changes an hour, and a deleted project can
#' be restored for `trash_days`. What the tools return is handed to the
#' app, which may send it to its provider's servers, so connect an app
#' only if the data may leave the computer that way.
#'
#' With `auth = "none"` any app that is given the address is let in, as the
#' local user. With `auth = "oidc"` the app must be approved by the person
#' it works for: the server is an OAuth 2.1 authorization server for its
#' own `/mcp` endpoint, the person signs in as they do in the browser and
#' chooses whether the app may only read or may also change things, and can
#' disconnect it again. An app identifies itself with a Client ID Metadata
#' Document, an https address that the server fetches; addresses inside
#' private networks are refused. The endpoint follows revision 2026-07-28
#' of the MCP specification, and also answers apps that only know the
#' revisions of 2025.
#'
#' @section Database:
#' The database is the file `sqlite.db` in `data_dir`. When a newer version
#' of atima needs to change its structure, the server first saves a copy as
#' `sqlite.db.v<N>.<date>.bak` in the same directory, then upgrades the
#' database in place.
#'
#' @section Jobs:
#' A plot, an upload, an export and anything else that reads a project's
#' data is a job, run by a worker process. `cpus` is the number of CPU
#' cores the whole server may use. One of them is kept for the process that
#' answers requests (unless `cpus` is 1), and there is a worker process for
#' each of the others, but no more than one for every 2 GB of the
#' computer's memory, since each is an R session with 'rbiom' loaded. So
#' with `cpus = 8`, seven jobs can run at the same time.
#'
#' Most of what 'rbiom' does runs on one core however many it is given; a
#' few steps, such as computing the distances between samples, use several
#' for a moment at the start of a job. A job that calls an 'rbiom' function
#' with a `cpus` argument is therefore told it may use the cores that are
#' free when it starts: all of them with `auth = "none"`, half of them on a
#' shared server so that the next job finds some free, and its share of
#' them when other jobs are waiting too. After that, atima does not assume
#' the job is using what it was given: four times a second it measures how
#' much of the processor each worker is using, and counts that. A job that
#' has finished its parallel step is counted as the one core it uses, and
#' the rest are free for others. A new job starts as soon as a worker and
#' one core are free, in the order the jobs arrived, so a large job cannot
#' hold up small ones for long, nor they it.
#'
#' A request that needs a worker waits in a queue if none is free.
#' The queue holds ten jobs per worker; when it is full, further requests
#' are answered 503 ("the server is busy") until there is room. On a shared
#' server one person may have `jobs_per_user` jobs waiting or running; the
#' next is answered 429 with a message to wait, so that one person's browser
#' tabs, or one AI app calling many tools at once, cannot fill the queue for
#' everyone else.
#' A new plot, rarefaction or table page from a browser tab replaces that
#' tab's earlier request of the same kind if it is still waiting or running.
#' A job that passes `time_limit`, or is replaced, is interrupted; if it has
#' not stopped five seconds later, its worker process is ended and a new one
#' takes its place. A local install (`auth = "none"`) has no time limit
#' unless `time_limit` is given: an analysis that is stopped on a shared
#' server can be run to its end on one's own computer.
#'
#' @section Cleanup:
#' When the server starts, and every ten minutes after that, it deletes
#' closed and expired sessions, working copies that no session has open,
#' guests who have not returned, projects that were deleted `trash_days`
#' ago, private projects that nobody has in their project tree any more,
#' connections of AI apps that have run out, stored files that nothing
#' refers to, and old temporary files. See `session_hours` and `guest_days`.
#' A shared server also deletes its record of single actions and visits
#' once it is `usage_months` old.
#' Saved projects that belong to a signed-in user are never erased unless
#' somebody deleted them.
#'
#' @section Server log:
#' The server writes one line of JSON per request and per error to standard
#' error. An error shown in the browser carries a short id; the log line with
#' the same `id` has the details. To write the log to a file instead, set
#' `options(atima.log = "path/to/atima.log")` before calling `run()`.
#'
#' @return Does not return; the server runs until the R session is
#'         interrupted. It then cancels running jobs, stops the worker
#'         processes and closes the database.
#' @export
#' @examples
#' if (interactive()) {
#'   # Serve on http://127.0.0.1:8080 and keep data in a temporary directory.
#'   atima::run(data_dir = tempfile("atima_data_"))
#' }
run <- function(
    port          = 8080,
    host          = '127.0.0.1',
    auth          = 'none',
    public_url    = NULL,
    oidc_issuer   = 'https://auth.globus.org',
    oidc_client_id     = NULL,
    oidc_client_secret = NULL,
    admins        = NULL,
    forwarded_proto_header = NULL,
    client_ip_header = NULL,
    signin_days   = 30,
    operator      = NULL,
    contact       = NULL,
    data_dir     = tools::R_user_dir('atima', 'data'),
    temp_dir      = tempfile(pattern = 'atima_'),
    cpus          = parallelly::availableCores(),
    time_limit    = NULL,
    jobs_per_user = 16,
    cache_size_mb = 100,
    max_upload_mb = 50,
    session_hours = 24,
    guest_days    = 30,
    trash_days    = 30,
    mcp_writes    = TRUE,
    app_days      = 30,
    app_changes_per_hour = 60,
    usage         = TRUE,
    usage_months  = 25,
    geo_db        = NULL,
    legacy        = NULL,
    open          = interactive() ) {

  message("Initializing Atima Server...")

  # Nobody has asked this server to stop yet (`R/shutdown.R`).
  shutdown$requested <- FALSE

  #______________________________________________
  # 1. Argument Resolution & Validation
  #
  explicits <- if (nargs() > 0) mget(names(match.call())[-1]) else list()

  optional <- c(
    'time_limit', 'public_url', 'oidc_client_id', 'oidc_client_secret',
    'admins', 'forwarded_proto_header', 'client_ip_header', 'operator', 'contact' )

  find_arg <- function(param, cls) {

    val <- if (hasName(explicits, param)) { explicits[[param]]
    } else if (nzchar(x <- Sys.getenv(paste0('ATIMA_', toupper(param))))) { x
    } else if (!is.null(x <- getOption(paste0('atima.', param)))) { x
    } else if (param %in% formalArgs(run)) { get(param, parent.frame())
    } else { NULL }

    if (param %in% optional && is.null(val)) return (val)

    if (is.null(val))     stop(param, ' cannot be NULL.')
    if (param == 'admins') val <- paste(val, collapse = ',')
    if (length(val) != 1)  stop(param, ' must be a single value.')
    if (is.na(val))        stop(param, ' cannot be NA.')

    tryCatch(
      error = function (e) stop("Error with '", param, "' parameter: ", e),
      expr  = switch(
        EXPR = cls,
        'int'  = as.integer(as.vector(val)),
        'chr'  = as.character(as.vector(val)),
        'bool' = as.logical(as.vector(val)),
        stop('invalid class: ', cls)))
  }

  port          <- find_arg('port',          'int')
  host          <- find_arg('host',          'chr')
  data_dir      <- find_arg('data_dir',      'chr')
  temp_dir      <- find_arg('temp_dir',      'chr')
  time_limit    <- find_arg('time_limit',    'int')
  jobs_per_user <- find_arg('jobs_per_user', 'int')
  cache_size_mb <- find_arg('cache_size_mb', 'int')
  max_upload_mb <- find_arg('max_upload_mb', 'int')
  cpus          <- find_arg('cpus',          'int')
  session_hours <- find_arg('session_hours', 'int')
  guest_days    <- find_arg('guest_days',    'int')
  open          <- find_arg('open',          'bool')
  signin_days   <- find_arg('signin_days',   'int')
  trash_days    <- find_arg('trash_days',    'int')
  app_days      <- find_arg('app_days',      'int')
  mcp_writes    <- find_arg('mcp_writes',    'bool')
  app_changes_per_hour <- find_arg('app_changes_per_hour', 'int')
  usage         <- find_arg('usage',         'bool')
  usage_months  <- find_arg('usage_months',  'int')
  client_ip_header <- find_arg('client_ip_header', 'chr')
  operator      <- text_setting(find_arg('operator', 'chr'), 'operator')
  contact       <- text_setting(find_arg('contact',  'chr'), 'contact')

  # A list of files, so not one value as the other settings are.
  legacy <- if (hasName(explicits, 'legacy')) { explicits[['legacy']]
  } else if (nzchar(x <- Sys.getenv('ATIMA_LEGACY'))) { x
  } else { getOption('atima.legacy') }
  legacy <- legacy_register(legacy_setting(legacy))

  # Also a list of files.
  geo_db <- if (hasName(explicits, 'geo_db')) { explicits[['geo_db']]
  } else if (nzchar(x <- Sys.getenv('ATIMA_GEO_DB'))) { x
  } else { getOption('atima.geo_db') }
  geo_db <- geo_setting(geo_db)

  auth_cfg <- auth_settings(
    auth          = find_arg('auth', 'chr'),
    host          = host,
    port          = port,
    public_url    = find_arg('public_url', 'chr'),
    issuer        = find_arg('oidc_issuer', 'chr'),
    client_id     = find_arg('oidc_client_id', 'chr'),
    client_secret = find_arg('oidc_client_secret', 'chr'),
    admins        = find_arg('admins', 'chr'),
    forwarded_proto_header = find_arg('forwarded_proto_header', 'chr') )

  if (is.null(time_limit))
    time_limit <- default_time_limit(auth_cfg[['auth']])

  for (param in c(
      'cpus', 'time_limit', 'jobs_per_user', 'session_hours', 'guest_days', 'signin_days',
      'trash_days', 'app_days', 'app_changes_per_hour', 'usage_months' ))
    if (get(param) < 1) stop(param, ' must be at least 1.')

  if (is.na(mcp_writes)) stop('mcp_writes must be TRUE or FALSE.')
  if (is.na(usage))      stop('usage must be TRUE or FALSE.')

  if (!is.null(client_ip_header) && !grepl("^[A-Za-z0-9-]+$", client_ip_header))
    stop('client_ip_header must be the name of a request header, such as "X-Real-IP".', call. = FALSE)

  # Settings of earlier versions that `cpus` replaced.
  for (old in c('workers', 'max_cpus'))
    if (nzchar(Sys.getenv(paste0('ATIMA_', toupper(old)))) || !is.null(getOption(paste0('atima.', old))))
      message(' - Note: the setting `', old, '` is no longer used. Set `cpus` (ATIMA_CPUS) instead.')

  # One core is the web server's own, where there is more than one.
  server  <- if (cpus > 1) 1L else 0L
  workers <- pool_workers(cpus - server)

  cache_size_bytes <- cache_size_mb * 1024 * 1024
  max_upload_bytes <- max_upload_mb * 1024 * 1024


  #______________________________________________
  # 2. Environment & Database Setup
  #
  data_dir <- normalizePath(data_dir, winslash = "/", mustWork = FALSE)
  temp_dir <- normalizePath(temp_dir, winslash = "/", mustWork = FALSE)

  if (dirs_overlap(temp_dir, data_dir))
    stop('temp_dir must not be the same as data_dir, or inside it, or contain it.')

  if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)
  if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)

  message(' - Data Directory: ', data_dir)
  message(' - Temp Directory: ', temp_dir)


  config <- list(
    data_dir    = data_dir,
    temp_dir    = temp_dir,
    cache_size  = cache_size_bytes,
    time_limit  = time_limit,
    cpus        = cpus,
    workers     = workers,
    session_ttl = session_hours * 3600,
    guest_ttl   = guest_days * 86400,
    signin_ttl  = signin_days * 86400,
    trash_ttl   = trash_days * 86400,
    # The largest upload, for the app to state beside its upload buttons.
    max_upload_mb = max_upload_mb,
    # AI apps: how long a connection lasts unused, whether the tools that
    # change data are offered, and how many changes one app may make an hour.
    app_ttl     = app_days * 86400,
    mcp_writes  = mcp_writes,
    app_changes_per_hour = app_changes_per_hour,
    legacy      = legacy,
    # Who runs the server and how to reach them, for the app's "Privacy and
    # terms" page.
    operator    = operator,
    contact     = contact,
    auth        = auth_cfg[['auth']],
    public_url  = auth_cfg[['public_url']],
    # The address to put in front of links that leave the browser, such as
    # those in the results of tools called by AI apps.
    base_url    = auth_cfg[['public_url']] %||% local_url(host, port),
    forwarded_proto_header = auth_cfg[['forwarded_proto_header']],
    # Usage monitoring (`R/usage.R`): only ever on a server with accounts.
    client_ip_header = client_ip_header,
    usage        = usage && auth_cfg[['auth']] == 'oidc',
    usage_months = usage_months
  )

  # The files in which a visitor's country and network are looked up.
  geo <- if (usage_on(config)) geo_open(geo_db)
  for (file in if (!is.null(geo)) geo_db)
    message(' - Country and network lookup: ', file)

  message(' - Sign-in: ', if (config[['auth']] == 'none') 'none (single local user)' else paste('OpenID Connect,', auth_cfg[['oidc']][['issuer']]))

  for (source in legacy)
    message(' - Legacy import: ', source[['label']], ' (', source[['path']], ')')

  for (subdir in file.path(data_dir, c('files', 'cache')))
    if (!dir.exists(subdir)) dir.create(subdir, recursive = TRUE)

  # Everything set up from here on is taken down again, in reverse order,
  # when the server stops: the cleanup timer, the workers (cancelling their
  # jobs), then the database.
  db <- db_open(data_dir)
  on.exit(db_close(db), add = TRUE, after = FALSE)

  # Stops here if the installed rbiom is too old to describe its functions.
  rbiom_schema()

  storage_adopt_legacy(db, file.path(data_dir, 'files'))

  message(
    ' - CPU cores: ', cpus, ' (', server, ' for this process). Starting ', workers, ' worker process', if (workers > 1) 'es',
    if (workers < cpus - server) ' (limited by memory)' )
  # A local install has one user, who may fill the queue if they like.
  message(' - Time limit for one job: ', if (is.finite(time_limit)) paste(time_limit, 'seconds') else 'none')
  pool <- pool_start(
    workers    = workers,
    cores      = cpus,
    server     = server,
    # A local install has one user, whose job may take every free core.
    most       = if (config[['auth']] == 'none') 1 else 0.5,
    time_limit = time_limit,
    timeout_note = if (config[['auth']] != 'none') timeout_note_shared,
    max_user   = if (config[['auth']] == 'none') Inf else jobs_per_user )
  on.exit(pool_stop(pool), add = TRUE, after = FALSE)

  if (db_is_empty(db)) {
    message(' - Loading example projects')
    db_seed(db, config, pool)
  }

  auth_state <- auth_new(config[['auth']], auth_cfg[['oidc']])

  # Find the provider now, so that a wrong issuer shows at start-up. If it
  # cannot be reached, the server still starts and tries again when
  # someone signs in.
  if (config[['auth']] == 'oidc')
    tryCatch(
      expr  = auth_state[['provider']] <- oidc_discover(auth_cfg[['oidc']][['issuer']]),
      error = function (e) {
        message(' - Warning: the sign-in provider is not usable yet: ', conditionMessage(e))
        log_event("error", "oidc_discovery_failed", message = log_truncate(conditionMessage(e), 2000L))
      })

  # A local install has one user, who owns whatever is in the database.
  if (config[['auth']] == 'none')
    db_transaction(db, local_owner(db))

  app_state <- list(
    db = db, config = config, pool = pool, memo = memo_new(), auth = auth_state, legacy = legacy_state(),
    geo = geo )

  stop_cleanup <- cleanup_start(app_state)
  on.exit(stop_cleanup(), add = TRUE, after = FALSE)

  # A shared server notes how busy it is every minute, and counts its
  # record of use into daily numbers every ten.
  if (usage_on(config)) {
    stop_usage <- usage_start(app_state)
    on.exit(stop_usage(), add = TRUE, after = FALSE)
  }


  #______________________________________________
  # 3. HTTP Application Definition
  #

  app <- list(

    'onHeaders' = function(req) {

      tryCatch(
        error = function (e) { response(e$message, 500L) },
        expr  = {
          method <- toupper(req[['REQUEST_METHOD']])

          if (identical(method, "POST")) {

            len <- suppressWarnings(as.numeric(req$CONTENT_LENGTH))

            if (length(len) != 1 || is.na(len)) {
              response("Content-Length Required", 411L)
            }
            else if (isTRUE(len > max_upload_bytes)) {
              response("File Upload Size Too Large", 413L)
            }
            else {
              NULL
            }
          }
          else if (!identical(method, "GET")) {
            response('Method Not Allowed', 405L)
          }
          else {
            NULL # request is valid.
          }
        }
      )
    },

    # The answer is a response, or a promise of one while a worker is busy
    # with the request. Either way this returns at once.
    'call' = function(req) {
      interruptible(handle_request(req, app_state), stopping_response())
    },

    'staticPaths' = static_paths(temp_dir),

    'staticPathOptions' = staticPathOptions(indexhtml = FALSE)
  )

  #______________________________________________
  # 4. Start Server
  #
  url <- if (config[['auth']] == 'oidc') config[['public_url']] else local_url(host, port)
  message("Server listening on ", host, " port ", port, ". Open ", url)
  message(
    "AI apps can connect to ", url, "/mcp",
    if (config[['auth']] == 'oidc') " (each person approves an app when it first connects)",
    if (!mcp_writes) "; they can read and analyse, not change anything" )

  if (open) utils::browseURL(url)

  on.exit(message("Stopping the Atima server..."), add = TRUE, after = FALSE)

  serve(host, port, app)
}


#______________________________________________________________________________
#' Internal: check the authentication settings and put them in order.
#'
#' @return `list(auth, public_url, forwarded_proto_header, oidc)`, where
#'         `oidc` is `NULL` or `list(issuer, client_id, client_secret,
#'         redirect_uri, admins)`. Stops if the settings cannot be used.
#' @noRd
auth_settings <- function (
    auth, host, port, public_url = NULL, issuer = NULL, client_id = NULL,
    client_secret = NULL, admins = NULL, forwarded_proto_header = NULL ) {

  if (!is_one_of(auth, auth_modes))
    stop('auth must be "none" or "oidc".', call. = FALSE)

  if (!is.null(forwarded_proto_header) && !grepl("^[A-Za-z0-9-]+$", forwarded_proto_header))
    stop('forwarded_proto_header must be the name of a request header, such as "X-Forwarded-Proto".', call. = FALSE)


  # Without accounts, the server must not be reachable from elsewhere.
  if (auth == "none") {

    if (!is_loopback_host(host))
      stop(call. = FALSE, sprintf(paste(
        'auth = "none" has no accounts, so it only runs on this computer,',
        'and host = "%s" would let other computers connect.',
        'Use host = "127.0.0.1", or set auth = "oidc" for a shared server.' ), host))

    return (list(auth = auth, public_url = NULL, forwarded_proto_header = forwarded_proto_header, oidc = NULL))
  }


  if (is.null(client_id) || !nzchar(client_id) || is.null(client_secret) || !nzchar(client_secret))
    stop(call. = FALSE, paste(
      'auth = "oidc" needs the client id and secret from your provider:',
      'set oidc_client_id and oidc_client_secret, or the environment variables',
      'ATIMA_OIDC_CLIENT_ID and ATIMA_OIDC_CLIENT_SECRET.' ))

  if (!oidc_url_ok(issuer))
    stop('oidc_issuer must be an https:// URL.', call. = FALSE)

  if (is.null(public_url)) {
    if (!is_loopback_host(host))
      stop('auth = "oidc" needs public_url, the address people use to reach this server, e.g. "https://atima.example.org".', call. = FALSE)
    public_url <- sprintf("http://localhost:%d", as.integer(port))
  }

  public_url <- sub("/+$", "", public_url)

  if (!grepl("^https?://[^/?#[:space:]]+$", public_url))
    stop('public_url must look like "https://atima.example.org", with no path.', call. = FALSE)

  if (!oidc_url_ok(public_url))
    stop('public_url must start with https://, unless it is a localhost address.', call. = FALSE)

  if (!is.null(admins)) {
    admins <- trimws(strsplit(admins, ",", fixed = TRUE)[[1]])
    admins <- admins[nzchar(admins)]
  }

  list(
    auth                   = auth,
    public_url             = public_url,
    forwarded_proto_header = forwarded_proto_header,
    oidc                   = list(
      issuer        = issuer,
      client_id     = client_id,
      client_secret = client_secret,
      redirect_uri  = paste0(public_url, "/auth/callback"),
      admins        = admins ))
}


#______________________________________________________________________________
#' Internal: check a setting that is a short line of text shown in the app
#' (`operator`, `contact`).
#'
#' @param value  The setting, or `NULL`.
#' @param name   Its name, for the error message.
#' @return The text without surrounding spaces, or `NULL` if there is none.
#'         Stops if it has more than one line or is too long.
#' @noRd
text_setting <- function (value, name, max = 200L) {

  if (is.null(value)) return (NULL)

  if (!is_scalar_character(value) || is.na(value))
    stop(name, ' must be a single string.', call. = FALSE)

  value <- trimws(value)
  if (!nzchar(value)) return (NULL)

  if (grepl("[[:cntrl:]]", value))
    stop(name, ' must be one line of text.', call. = FALSE)

  if (nchar(value) > max)
    stop(name, ' must be at most ', max, ' characters.', call. = FALSE)

  value
}


#______________________________________________________________________________
#' Internal: the directories httpuv serves as they are, without calling the
#' router: the app's own files under `/www`, and figures and exports under
#' `/tmp/<session key>/`.
#'
#' Browsers are told to ask before reusing one of the app's files. Without
#' that they guess how long a script stays fresh, and after an upgrade (or
#' an edit, during development) run old scripts against the new server. The
#' answer to "has it changed?" is a short 304. Files under `/tmp` never
#' change once written, so they need no such header.
#'
#' @param temp_dir  The server's temporary directory.
#' @return A named list for httpuv's `staticPaths`.
#' @noRd
static_paths <- function (temp_dir) {
  list(
    '/www' = staticPath(
      path    = system.file(package = 'atima', 'www'),
      headers = list('Cache-Control' = "no-cache", 'X-Content-Type-Options' = "nosniff") ),
    '/tmp' = staticPath(
      path    = temp_dir,
      headers = list('X-Content-Type-Options' = "nosniff") ))
}


#______________________________________________________________________________
#' Internal: URL a browser on this machine can use to reach the server.
#'
#' Wildcard listen addresses ("0.0.0.0", "::") are not valid destinations, so
#' they are mapped to the loopback address. IPv6 literals get brackets.
#' @noRd
local_url <- function (host, port) {
  if (host %in% c('0.0.0.0', ''))  host <- '127.0.0.1'
  if (host %in% c('::', '[::]'))   host <- '::1'
  if (grepl(':', host, fixed = TRUE) && !startsWith(host, '['))
    host <- paste0('[', host, ']')
  sprintf("http://%s:%d", host, as.integer(port))
}


#______________________________________________________________________________
#' Internal: the single page of the app, `inst/www/index.html`, with the
#' version numbers filled in.
#'
#' The file is read when the first page is asked for, not when the package
#' is built, so that it is the installed file that is served. Everything
#' the page loads comes from this server, which the Content-Security-Policy
#' states: no other host is contacted, and no script written into the page
#' runs.
#' @noRd
index_html <- local({

  page <- NULL

  function () {

    if (is.null(page)) {

      html <- readLines(system.file(package = "atima", "www", "index.html", mustWork = TRUE), encoding = "UTF-8", warn = FALSE)
      html <- paste(enc2utf8(html), collapse = "\n")
      html <- gsub("{{atima_version}}", as.character(packageVersion("atima")), html, fixed = TRUE)
      html <- gsub("{{rbiom_version}}", as.character(packageVersion("rbiom")), html, fixed = TRUE)

      page <<- response(
        status  = 200L,
        body    = html,
        headers = list(
          'Content-Type'            = "text/html; charset=utf-8",
          'Cache-Control'           = "no-cache",
          'Content-Security-Policy' = content_security_policy,
          'Referrer-Policy'         = "same-origin",
          'X-Content-Type-Options'  = "nosniff",
          'X-Frame-Options'         = "DENY" ))
    }

    page
  }
})

# What the app's page may load: scripts, styles, fonts, images and API
# calls from this server only, and nothing written inline.
content_security_policy <- paste(
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data: blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  sep = "; " )


#______________________________________________________________________________
#' Internal: route handler for the pages that load the single-page app.
#' @noRd
serve_index <- function (REQ, access_key = NULL) {
  index_html()
}
