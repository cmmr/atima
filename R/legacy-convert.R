#______________________________________________________________________________
#' Save an atima 2 database for importing
#'
#' Copies what the "Import from an older atima" page needs out of an
#' atima 2 database (MariaDB or MySQL) into one SQLite file. Run it once,
#' then name the file in the `legacy` setting of [run()]. The old database
#' is only read.
#'
#' The file holds, for every account with an email address: the email
#' address, the bcrypt hash of the password, and the account's encrypted
#' private key; and for every project that was not deleted: who could open
#' it, and its BIOM file, metadata, taxonomy, tree, name and rarefaction
#' depth, each still encrypted exactly as atima 2 stored it. Nothing is
#' decrypted, so the file is as sensitive as the old database and no more:
#' a project in it can only be read with the password of someone who had
#' access to it. Names, affiliations, sessions, sign-in tokens and cached
#' results are left out. People who could only view a public project of
#' the old site are not listed for it, since everyone had every public
#' project.
#'
#' @param con   A DBI connection to the atima 2 database, for example from
#'              `DBI::dbConnect(RMariaDB::MariaDB(), ...)`. An account that
#'              may only `SELECT` is enough.
#' @param file  The SQLite file to write. It must not exist yet.
#'
#' @return `file`, invisibly. The numbers of accounts, projects and objects
#'         copied are reported as messages.
#' @export
#' @examples
#' \dontrun{
#' con <- DBI::dbConnect(
#'   RMariaDB::MariaDB(),
#'   dbname = "atima", host = "localhost",
#'   user = "readonly", password = Sys.getenv("ATIMA2_DB_PASSWORD") )
#'
#' atima::legacy_convert(con, "atima2.sqlite")
#' DBI::dbDisconnect(con)
#'
#' atima::run(auth = "oidc", legacy = c("ATIMA 2" = "atima2.sqlite"))
#' }
legacy_convert <- function (con, file) {

  stopifnot(is(con, "DBIConnection"), is_scalar_character(file))

  if (file.exists(file))
    stop("'", file, "' already exists. Choose another name, or delete it first.")

  # MySQL table names may be case sensitive, and installations differ.
  tables <- dbListTables(con)
  table  <- function (name) {
    found <- tables[tolower(tables) == name]
    if (length(found) != 1) stop("This is not an atima 2 database: it has no '", name, "' table.")
    as.character(DBI::dbQuoteIdentifier(con, found))
  }

  t_users       <- table("users")
  t_projects    <- table("projects")
  t_permissions <- table("permissions")
  t_objects     <- table("objects")

  # Ids are BIGINT, which some drivers return as 64-bit integers or text.
  id   <- function (x) as.numeric(as.character(x))
  time <- function (x) if (inherits(x, "POSIXt")) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC") else as.character(x)

  message("Reading accounts")

  users <- dbGetQuery(con, paste(
    "SELECT `UserID`, `Email Address`, `Hashed Password`, `User Key Salt`, `Private Key`",
    "FROM", t_users,
    "WHERE `Email Address` IS NOT NULL AND `Hashed Password` IS NOT NULL AND `User Key Salt` IS NOT NULL" ))

  users <- data.frame(
    stringsAsFactors = FALSE,
    user_id         = id(users[[1]]),
    email           = tolower(trimws(users[[2]])),
    hashed_password = users[[3]],
    user_key_salt   = users[[4]],
    private_key     = users[[5]] )

  users <- users[nzchar(users[['email']]) & !duplicated(users[['email']]), , drop = FALSE]

  message("Reading projects")

  projects <- dbGetQuery(con, paste(
    "SELECT `ProjectID`, `Created` FROM", t_projects, "WHERE `Deleted` IS NULL" ))

  projects <- data.frame(
    stringsAsFactors = FALSE,
    project_id = id(projects[[1]]),
    created    = time(projects[[2]]) )

  perms <- dbGetQuery(con, paste(
    "SELECT `UserID`, `ProjectID`, `Editor`, `Encryption Key` FROM", t_permissions ))

  perms <- data.frame(
    stringsAsFactors = FALSE,
    user_id        = id(perms[[1]]),
    project_id     = id(perms[[2]]),
    is_editor      = as.integer(as.logical(as.numeric(perms[[3]]))),
    encryption_key = perms[[4]] )

  # atima 2's stand-in for "everyone" was user 1: a project that user 1
  # could open was public, and every account was given a copy of its key.
  public <- perms[['project_id']][perms[['user_id']] == 1]

  perms <- perms[
    perms[['user_id']]    %in% users[['user_id']] &
    perms[['project_id']] %in% projects[['project_id']] &
    (perms[['is_editor']] == 1L | !perms[['project_id']] %in% public), , drop = FALSE]

  projects <- projects[projects[['project_id']] %in% perms[['project_id']], , drop = FALSE]
  users    <- users[users[['user_id']] %in% perms[['user_id']], , drop = FALSE]

  out <- dbConnect(SQLite(), dbname = file)
  ok  <- FALSE

  on.exit(add = TRUE, expr = {
    dbDisconnect(out)
    if (!ok) unlink(file)
  })

  for (sql in c(
    "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "CREATE TABLE users (
       user_id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, hashed_password TEXT NOT NULL,
       user_key_salt TEXT NOT NULL, private_key TEXT NOT NULL)",
    "CREATE TABLE projects (project_id INTEGER PRIMARY KEY, created TEXT NULL)",
    "CREATE TABLE permissions (
       user_id INTEGER NOT NULL, project_id INTEGER NOT NULL, is_editor INTEGER NOT NULL,
       encryption_key TEXT NOT NULL, PRIMARY KEY (user_id, project_id))",
    "CREATE TABLE objects (
       project_id INTEGER NOT NULL, object_name TEXT NOT NULL, md5sum TEXT NOT NULL,
       base64 TEXT NOT NULL, PRIMARY KEY (project_id, object_name))" ))
    dbExecute(out, sql)

  dbExecute(out, "BEGIN")

  insert <- function (table, rows) {
    if (nrow(rows) == 0) return (invisible(NULL))
    sql <- sprintf(
      "INSERT OR REPLACE INTO %s (%s) VALUES (%s)",
      table, paste(names(rows), collapse = ", "), paste(rep("?", ncol(rows)), collapse = ", ") )
    dbExecute(out, sql, params = unname(as.list(rows)))
  }

  insert("users",       users)
  insert("projects",    projects)
  insert("permissions", perms)

  message("Copying the objects of ", nrow(projects), " project", if (nrow(projects) != 1) "s")

  names_sql <- paste0("'", atima2_objects, "'", collapse = ", ")
  n_objects <- 0L

  # One project at a time: an object can be many megabytes.
  for (project_id in projects[['project_id']]) {

    objects <- dbGetQuery(con, sprintf(
      "SELECT `Object Name`, `md5sum`, `Base64` FROM %s WHERE `ProjectID` = %.0f AND `Object Name` IN (%s) ORDER BY `ObjectID`",
      t_objects, project_id, names_sql ))

    if (nrow(objects) == 0) next

    insert("objects", data.frame(
      stringsAsFactors = FALSE,
      project_id  = project_id,
      object_name = objects[[1]],
      md5sum      = objects[[2]],
      base64      = objects[[3]] ))

    n_objects <- n_objects + nrow(objects)
  }

  insert("meta", data.frame(
    stringsAsFactors = FALSE,
    key   = c("format", "source_id", "converted_utc"),
    value = c("atima2", random_key(20L), format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")) ))

  dbExecute(out, "COMMIT")
  ok <- TRUE

  message(
    "Wrote ", file, ": ", nrow(users), " account", if (nrow(users) != 1) "s", ", ",
    nrow(projects), " project", if (nrow(projects) != 1) "s", ", ", n_objects, " objects." )

  invisible(file)
}
