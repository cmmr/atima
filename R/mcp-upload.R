#______________________________________________________________________________
# Uploading a file for a tool call.
#
# A tool's arguments are JSON, and the protocol has no way to send a file.
# So the tools `upload_project` and `upload_component` only issue a ticket,
# and return the command that sends the file with it:
#
#   curl -F ticket=<ticket> -F file=@<path> <server>/api/upload
#
# An app that can run commands runs it; otherwise the person does. The
# ticket says whose upload it is and what it is for (a new project, or a
# replacement for one part of a project the caller may edit), works once,
# and stops working after `upload_ticket_ttl` seconds. The database keeps
# its SHA-256 only. The server never fetches a file from an address a
# caller names: that would let a caller point it at computers inside the
# server's own network.
#
# `POST /api/upload` needs no cookie and no bearer token: the ticket is the
# permission, as a project's private key is for a download. The file then
# goes the way of a browser's upload (`work_import()`, `work_component()`),
# under the same size limit and the same per-account job limit, and what
# became of it is kept in the ticket's row for `upload_status`.
#______________________________________________________________________________


# Seconds an upload ticket can be used, and the most unused tickets one
# connection may hold.
upload_ticket_ttl <- 900
upload_ticket_max <- 10L


#______________________________________________________________________________
#' Issue an upload ticket.
#'
#' @param what        `"project"`, or the part of a project to replace:
#'                    `"metadata"`, `"taxonomy"` or `"tree"`.
#' @param project_id  For a part: the project.
#' @param title       For a project: its title, or `NULL` to use the file's
#'                    name.
#' @param inflate     For a project: scale counts that are not whole
#'                    numbers?
#' @return The tool's result: the upload's number, the command, and how
#'         long the ticket lasts.
#' @noRd
upload_ticket <- function (REQ, what, project_id = NULL, title = NULL, inflate = FALSE) {

  DB     <- REQ[['DB']]
  caller <- mcp_caller(REQ)
  now    <- Sys.time()

  held <- if (is.null(caller[['grant_id']])) {
    sql <- "SELECT COUNT(*) FROM app_uploads WHERE user_id = ? AND grant_id IS NULL AND state = 'waiting' AND expires_utc > ?"
    db_query(DB, sql, "UTick1", list(caller[['user_id']], sql_time(now)))
  } else {
    sql <- "SELECT COUNT(*) FROM app_uploads WHERE grant_id = ? AND state = 'waiting' AND expires_utc > ?"
    db_query(DB, sql, "UTick2", list(caller[['grant_id']], sql_time(now)))
  }

  if (held >= upload_ticket_max)
    stop_http(429L, "This app holds ", upload_ticket_max, " upload tickets that have not been used. Use one, or wait for them to run out.")

  ticket <- paste0("atu_", random_string(40))

  upload_id <- db_insert(
    DB = DB, table = "app_uploads", err_code = "UTick3",
    user_id     = caller[['user_id']],
    grant_id    = caller[['grant_id']],
    app         = caller[['app']],
    ticket_sha  = as.character(sha256(ticket)),
    what        = what,
    project_id  = project_id,
    title       = title,
    inflate     = isTRUE(inflate),
    expires_utc = sql_time(now + upload_ticket_ttl) )

  url <- paste0(REQ[['CONFIG']][['base_url']], "/api/upload")

  list(data = list(
    upload     = as.integer(upload_id),
    command    = sprintf('curl -F "ticket=%s" -F "file=@PATH_TO_FILE" %s', ticket, url),
    expires_in = sprintf("%i minutes", as.integer(upload_ticket_ttl %/% 60)),
    note       = paste(
      "Nothing has been uploaded yet. Replace PATH_TO_FILE with the file's path and run the command on the",
      "computer the file is on, or give the command to the person to run. It works once. Any tool that can send",
      "a multipart form with the fields `ticket` and `file` will do in place of curl.",
      "Then call upload_status with this upload's number." )))
}


#' Start the upload of a new project.
#' @noRd
tool_upload_project <- function (REQ, title = NULL, inflate = FALSE) {
  upload_ticket(REQ, "project", title = title, inflate = inflate)
}


#' Start the upload of a replacement for a project's metadata, taxonomy or
#' tree.
#' @noRd
tool_upload_component <- function (REQ, project, component) {
  upload_ticket(REQ, component, project_id = REQ[['SESSION']][['project_id']])
}


#______________________________________________________________________________
#' What became of an upload of the caller's.
#' @noRd
tool_upload_status <- function (REQ, upload) {

  DB     <- REQ[['DB']]
  caller <- mcp_caller(REQ)

  sql <- "SELECT * FROM app_uploads WHERE upload_id = ? AND user_id = ?"
  row <- db_query(DB, sql, "UStat1", list(upload, caller[['user_id']]), simplify = FALSE)

  if (nrow(row) != 1)
    stop_not_found("There is no upload with that number.")

  # One connection is not told about another's uploads.
  grant_id <- if (is.na(row[['grant_id']])) NULL else as.integer(row[['grant_id']])
  if (!identical(grant_id, caller[['grant_id']]))
    stop_not_found("There is no upload with that number.")

  state <- row[['state']]

  # A file that arrived, and of which nothing more was heard.
  if (state == "received" && row[['expires_utc']] + 1800 < Sys.time())
    return (list(data = list(upload = upload, state = "failed", message = "The file arrived but could not be processed.", note = "Nothing was changed. Start the upload again.")))

  if (state == "waiting" && row[['expires_utc']] < Sys.time())
    return (list(data = list(upload = upload, state = "expired", note = "No file arrived in time. Start the upload again.")))

  if (state == "waiting")
    return (list(data = list(upload = upload, state = "waiting", note = "No file has arrived yet. Run the command that the upload tool returned.")))

  if (state == "received")
    return (list(data = list(upload = upload, state = "processing", note = "The file has arrived and is being read. Ask again in a moment.")))

  if (state == "failed")
    return (list(data = list(upload = upload, state = "failed", message = row[['message']], note = "Nothing was changed. The ticket is used up: start the upload again if it is to be retried.")))

  key <- NULL
  if (!is.na(row[['result_project_id']])) {
    sql <- "SELECT access_key, public_key, title, n_samples, n_taxa FROM projects WHERE project_id = ? AND deleted_utc IS NULL"
    key <- db_query(DB, sql, "UStat2", list(row[['result_project_id']]), simplify = FALSE)
  }

  if (is.null(key) || nrow(key) != 1)
    return (list(data = list(upload = upload, state = "done", message = row[['message']], note = "The project it went into no longer exists.")))

  list(data = list(
    upload  = upload,
    state   = "done",
    message = row[['message']],
    project = if (is.na(key[['public_key']])) key[['access_key']] else key[['public_key']],
    title   = key[['title']],
    samples = key[['n_samples']],
    taxa    = key[['n_taxa']] ))
}


#______________________________________________________________________________
#' The ticket row a ticket stands for, if it can still be used.
#' @param ticket  The ticket, wrapped in `secret()`.
#' @return The row of `app_uploads` as a list, or `NULL`.
#' @noRd
upload_find <- function (DB, ticket) {
  sql <- "SELECT * FROM app_uploads WHERE ticket_sha = ? AND state = 'waiting' AND expires_utc > ?"
  db_query(DB, sql, "UFind1", list(as.character(sha256(reveal(ticket))), sql_time(Sys.time())))
}


#______________________________________________________________________________
#' `POST /api/upload`: a file sent with an upload ticket. The router has
#' checked that the ticket can be used (the `upload_ticket` rule).
#'
#' The ticket is used up at once. If the file is then refused, the ticket's
#' row keeps the reason, for `upload_status`, and the sender is told it too.
#'
#' @param ticket  The ticket, wrapped in `secret()`.
#' @param file    The uploaded file: `list(filename, value)`.
#' @return list(project, title, message): the key and title of the project
#'         that was made or changed, and one sentence saying what happened.
#' @noRd
api_upload_ticket <- function (REQ, ticket, file) {

  DB     <- REQ[['DB']]
  CONFIG <- REQ[['CONFIG']]
  up     <- upload_find(DB, ticket)

  db_update(DB, "app_uploads", up[['upload_id']], "AUTick1", state = "received")

  user <- db_query(DB, "SELECT full_name FROM users WHERE user_id = ?", "AUTick2", list(up[['user_id']]))

  caller <- list(
    user_id  = as.integer(up[['user_id']]),
    grant_id = if (is.na(up[['grant_id']])) NULL else as.integer(up[['grant_id']]),
    app      = up[['app']] )

  # Whose job this is, for the per-account limit and for the log.
  REQ[['SESSION']] <- list(user_id = caller[['user_id']], full_name = user)

  check_change_cap(REQ, caller)

  # A part of a project: the caller must still be allowed to change it.
  if (up[['what']] != "project") {
    key <- db_query(DB, "SELECT access_key FROM projects WHERE project_id = ?", "AUTick3", list(up[['project_id']]))
    REQ[['SESSION']] <- c(
      caller_project(DB, caller[['user_id']], key, "editor"),
      list(full_name = user) )
  }

  dir <- file.path(CONFIG[['temp_dir']], "uploads")
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  infile <- tempfile(pattern = "upload_", tmpdir = dir)
  writeBin(object = file[['value']], con = infile)

  settle <- function (state, message, project_id = NULL) {
    db_update(DB, "app_uploads", up[['upload_id']], "AUTick4", state = state, message = message, result_project_id = project_id)
    unlink(infile)
  }

  failed <- function (e) {
    report <- error_report(e, REQ)
    settle("failed", report[['message']])
    response(
      body   = list(error = c(
        list(message = unbox(report[['message']]), id = unbox(report[['id']])),
        if (!is.null(report[['code']])) list(code = unbox(report[['code']])) )),
      status = report[['status']] )
  }

  done <- function (project_id, message) {

    settle("done", message, project_id)
    record_change(DB, caller, if (up[['what']] == "project") "upload_project" else "upload_component", message, project_id)

    sql     <- "SELECT access_key, public_key, title FROM projects WHERE project_id = ?"
    project <- db_query(DB, sql, "AUTick5", list(project_id), req1 = TRUE)

    list(
      project = unbox(if (is.na(project[['public_key']])) project[['access_key']] else project[['public_key']]),
      title   = unbox(project[['title']]),
      message = unbox(message) )
  }

  if (up[['what']] == "project") {

    title <- if (is.na(up[['title']])) upload_title(file[['filename']]) else up[['title']]

    return (job(
      fn     = "work_import",
      args   = list(ctx = worker_ctx(CONFIG), infile = infile, title = title, inflate = isTRUE(as.logical(up[['inflate']]))),
      failed = failed,
      finish = function (imported) {
        project_id <- add_project(REQ, imported)
        details    <- imported[['details']]
        done(project_id, sprintf(
          "Uploaded \"%s\" as a new project: %i samples, %i taxa.",
          details[['title']], as.integer(details[['n_samples']]), as.integer(details[['n_taxa']]) ))
      }))
  }

  job(
    fn     = "work_edit",
    args   = list(
      ctx  = worker_ctx(CONFIG),
      full = biom_path(REQ, REQ[['SESSION']][['full_bf_id']]),
      rare = biom_path(REQ, REQ[['SESSION']][['rare_bf_id']]),
      what = "component",
      args = list(component = up[['what']], infile = infile) ),
    failed = failed,
    finish = function (result) {
      project_set_files(REQ, result)
      details <- result[['details']]
      done(REQ[['SESSION']][['project_id']], sprintf(
        "Replaced the %s of \"%s\" with an uploaded file. The project now has %i samples and %i taxa.",
        up[['what']], REQ[['SESSION']][['title']], as.integer(details[['n_samples']]), as.integer(details[['n_taxa']]) ))
    })
}
