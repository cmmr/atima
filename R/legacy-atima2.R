#______________________________________________________________________________
# The atima 2 adapter for the legacy import (see `R/legacy.R`).
#
# Everything here runs in a worker process and reads a file written by
# `legacy_convert()`.
#
# How atima 2 protected a project, from its `lib/Crypto.r`:
#
#  * A user's password was stored as a bcrypt hash. A second bcrypt hash of
#    the same password, made with the user's own "key salt", gave the user
#    key: the SHA-256 of the base64-decoded last 31 characters of that hash.
#  * Each user had an RSA key pair. The private key was stored encrypted
#    with the user key (AES-GCM).
#  * Each project had a random AES key. Everyone with access to the project
#    had a copy of it, encrypted with their RSA public key.
#  * Each object of a project (the BIOM file as uploaded, and the metadata,
#    taxonomy and tree as last edited) was serialized, compressed with
#    bzip2, encrypted with the project key (AES-GCM), serialized again and
#    stored as base64.
#
# So nothing can be read without the user's password, and the password and
# every key derived from it exist only in this process's memory while one
# job runs.
#______________________________________________________________________________


# The objects of an atima 2 project that an import uses.
atima2_objects <- c("Biom Data", "Metadata", "Taxonomy", "Tree", "Project Name", "Rarefaction Level")


#______________________________________________________________________________
#' Decode standard base64, or return `NULL` if `x` is not valid base64.
#' @noRd
atima2_base64 <- function (x) {
  if (nchar(x) %% 4 != 0 || !grepl("^[A-Za-z0-9+/]*={0,2}$", x)) return (NULL)
  tryCatch(openssl::base64_decode(x), error = function (e) NULL)
}


#______________________________________________________________________________
#' The keys an atima 2 user key may have been.
#'
#' atima 2 base64-decoded the last 31 characters of a bcrypt hash. That text
#' is not valid base64: its length is not a multiple of four, and bcrypt's
#' own alphabet has a `.` where base64 has a `+`. What came out therefore
#' depended on the OpenSSL the server ran at the time. The versions of that
#' era decoded the complete groups of four characters and dropped the rest,
#' or returned nothing at all when a `.` was among them. Today's OpenSSL
#' refuses the text outright.
#'
#' Rather than assume one behaviour, this returns each key that a plausible
#' decoder would have produced, most likely first. AES-GCM authenticates
#' what it decrypts, so only the right key opens the user's private key.
#'
#' @param hash  `bcrypt::hashpw(password, key_salt)`.
#' @return A list of 32-byte keys.
#' @noRd
atima2_user_keys <- function (hash) {

  text  <- substr(hash, 30, 61)
  whole <- substr(text, 1, 4 * (nchar(text) %/% 4))

  # The complete groups before the first character base64 does not have.
  bad   <- regexpr("[^A-Za-z0-9+/]", whole)
  clean <- if (bad > 0) substr(whole, 1, 4 * ((bad - 1) %/% 4)) else whole

  decoded <- list(
    atima2_base64(whole),
    raw(0),
    atima2_base64(clean),
    atima2_base64(paste0(text, strrep("=", (4 - nchar(text) %% 4) %% 4))) )

  decoded <- unique(decoded[!vapply(decoded, is.null, logical(1))])

  lapply(decoded, openssl::sha256)
}


#______________________________________________________________________________
#' AES-GCM decryption as atima 2 did it: the initialisation vector travels
#' with the data, and early ones were longer than the 12 bytes that are used.
#' @noRd
atima2_aes_decrypt <- function (data, key) {
  openssl::aes_gcm_decrypt(data, key = key, iv = head(attr(data, "iv"), 12))
}


#______________________________________________________________________________
#' Decrypt one stored object with its project's key.
#' @param base64  The `base64` column of the `objects` table.
#' @return The R object atima 2 stored.
#' @noRd
atima2_decode_object <- function (base64, project_key) {
  data <- unserialize(openssl::base64_decode(base64))
  data <- atima2_aes_decrypt(data, project_key)
  unserialize(memDecompress(data, type = "bzip2"))
}


#______________________________________________________________________________
#' Check an email address and password against an atima 2 database.
#'
#' @param con       A connection to a file made by `legacy_convert()`.
#' @param email     The email address, lower case.
#' @param password  The password, as typed.
#' @return `NULL` if the two do not match an account. Otherwise
#'         `list(user_id, private_key)`, the account's id in the old
#'         database and its RSA private key.
#' @noRd
atima2_verify <- function (con, email, password) {

  user <- dbGetQuery(con, "SELECT * FROM users WHERE email = ?", params = list(email))

  # Spend the same time on an address nobody registered as on a wrong
  # password, so that the answer's delay does not say which it was.
  if (nrow(user) != 1) {
    bcrypt::hashpw(password, "$2a$12$abcdefghijklmnopqrstuu")
    return (NULL)
  }

  if (!isTRUE(bcrypt::checkpw(password, user[['hashed_password']])))
    return (NULL)

  hash <- bcrypt::hashpw(password, user[['user_key_salt']])
  data <- unserialize(openssl::base64_decode(user[['private_key']]))

  for (user_key in atima2_user_keys(hash)) {

    private_key <- tryCatch(
      expr  = unserialize(atima2_aes_decrypt(data, user_key)),
      error = function (e) NULL )

    if (!is.null(private_key))
      return (list(user_id = user[['user_id']], private_key = private_key))
  }

  # The password is right, yet none of the ways atima 2 may have derived
  # the user key opens the private key.
  stop_http(
    status = 500L,
    "This account's encryption key could not be rebuilt. Please report this to the administrator.",
    detail = paste("atima 2 user", user[['user_id']], ": no candidate user key decrypts the private key") )
}


#______________________________________________________________________________
#' The AES key of a project, from a user's own copy of it.
#' @return The key, or `NULL` if the user has no copy that decrypts.
#' @noRd
atima2_project_key <- function (encrypted, private_key) {
  tryCatch(
    expr  = unserialize(openssl::rsa_decrypt(openssl::base64_decode(encrypted), key = private_key)),
    error = function (e) NULL )
}


#______________________________________________________________________________
#' The projects an atima 2 user can open.
#'
#' @param user  What `atima2_verify()` returned.
#' @return A list with one entry per project:
#'         `list(id, title, created, is_editor, key)`. `key` is the
#'         project's AES key and must not leave the worker.
#' @noRd
atima2_projects <- function (con, user) {

  sql <- paste(
    "SELECT p.project_id, p.created, m.is_editor, m.encryption_key",
    "  FROM permissions m JOIN projects p USING (project_id)",
    " WHERE m.user_id = ?",
    "   AND EXISTS (SELECT 1 FROM objects o WHERE o.project_id = p.project_id AND o.object_name = 'Biom Data')",
    " ORDER BY p.created DESC, p.project_id DESC" )

  rows <- dbGetQuery(con, sql, params = list(user[['user_id']]))

  projects <- lapply(seq_len(nrow(rows)), function (i) {

    key <- atima2_project_key(rows[i, 'encryption_key'], user[['private_key']])
    if (is.null(key)) return (NULL)

    sql   <- "SELECT base64 FROM objects WHERE project_id = ? AND object_name = 'Project Name'"
    name  <- dbGetQuery(con, sql, params = list(rows[i, 'project_id']))
    title <- tryCatch(
      expr  = atima2_decode_object(name[1, 'base64'], key),
      error = function (e) NULL )

    if (!is_scalar_character(title) || is.na(title) || !nzchar(trimws(title)))
      title <- "Untitled project"

    list(
      id        = as.character(rows[i, 'project_id']),
      title     = substr(trimws(title), 1, 100),
      created   = rows[i, 'created'],
      is_editor = isTRUE(as.logical(rows[i, 'is_editor'])),
      key       = key )
  })

  projects[!vapply(projects, is.null, logical(1))]
}


#______________________________________________________________________________
#' Rebuild one atima 2 project as an rbiom object.
#'
#' The BIOM file is the one the user uploaded. atima 2 kept the metadata,
#' taxonomy and tree as separate objects, which the user could replace or
#' edit afterwards, so those are laid over what the file holds.
#'
#' @param project  One entry of `atima2_projects()`.
#' @param dir      A directory for the BIOM file.
#' @return `list(biom, file, depth)`: the rbiom object, the file as it was
#'         uploaded, and the rarefaction depth the project was set to
#'         (`NULL` if none was).
#' @noRd
atima2_fetch <- function (con, project, dir) {

  # atima 2 also stored an MD5 of each object. It is not checked: in the real
  # database it is wrong for objects that decrypt and read perfectly well,
  # and AES-GCM already refuses anything that was altered.
  sql  <- sprintf(
    "SELECT object_name, base64 FROM objects WHERE project_id = ? AND object_name IN (%s)",
    paste0("'", atima2_objects, "'", collapse = ", ") )
  rows <- dbGetQuery(con, sql, params = list(as.numeric(project[['id']])))

  objects <- list()

  for (i in seq_len(nrow(rows))) {

    name <- rows[i, 'object_name']

    objects[[name]] <- tryCatch(
      expr  = atima2_decode_object(rows[i, 'base64'], project[['key']]),
      error = function (e) {
        # The BIOM file is the project. Anything else can be done without.
        if (name == "Biom Data")
          stop_user("This project's data is damaged in the old database and cannot be imported.")
        NULL
      })
  }

  data <- objects[['Biom Data']]
  file <- tempfile("legacy_", tmpdir = dir, fileext = ".biom")

  if (is.character(data)) { writeChar(data, file, eos = NULL, useBytes = TRUE)
  } else                  { writeBin(as.raw(data), file) }

  biom <- with_user_errors(
    message = "This project's data could not be read as a BIOM file.",
    detail  = FALSE,
    code    = as_rbiom(file) )

  # Each of these is applied on its own: one that today's rbiom will not
  # accept is left out, and the project keeps what its BIOM file has.
  lay_over <- function (code) tryCatch(suppressWarnings(suppressMessages(code)), error = function (e) NULL)

  metadata <- atima2_metadata(objects[['Metadata']], biom$samples)
  if (!is.null(metadata)) lay_over(biom$metadata <- metadata)

  taxonomy <- atima2_taxonomy(objects[['Taxonomy']])
  if (!is.null(taxonomy)) lay_over(biom$taxonomy <- taxonomy)

  if (inherits(objects[['Tree']], "phylo")) lay_over(biom$tree <- objects[['Tree']])

  depth <- objects[['Rarefaction Level']]
  if (!(is.numeric(depth) && length(depth) == 1 && is.finite(depth) && depth >= 1)) depth <- NULL

  list(biom = biom, file = file, depth = depth)
}


#______________________________________________________________________________
#' atima 2's metadata table as rbiom wants one: a `.sample` column, and
#' dates as text.
#'
#' rbiom drops a sample that the metadata does not list. atima 2 did not: a
#' sample without a row simply had no metadata. So every sample of the
#' dataset gets a row here, empty if atima 2 had none for it.
#'
#' @param samples  The sample names of the dataset.
#' @noRd
atima2_metadata <- function (metadata, samples = character(0)) {

  if (!is.data.frame(metadata) || nrow(metadata) == 0) return (NULL)

  listed <- if (hasName(metadata, "SampleID")) as.character(metadata[['SampleID']]) else rownames(metadata)
  listed <- trimws(listed)

  metadata <- metadata[, setdiff(names(metadata), c("SampleID", ".sample")), drop = FALSE]

  for (i in seq_along(metadata))
    if (inherits(metadata[[i]], c("Date", "POSIXt")))
      metadata[[i]] <- as.character(metadata[[i]])

  rownames(metadata) <- NULL
  metadata <- cbind(data.frame(.sample = listed, stringsAsFactors = FALSE), metadata)

  missing <- setdiff(samples, listed)

  if (length(missing) > 0 && ncol(metadata) > 1) {
    blank <- metadata[rep(NA_integer_, length(missing)), , drop = FALSE]
    blank[['.sample']] <- missing
    metadata <- rbind(metadata, blank)
    rownames(metadata) <- NULL
  }

  metadata
}


#______________________________________________________________________________
#' atima 2's taxonomy (a character matrix with OTU names as row names) as
#' rbiom wants one: a data frame with an `.otu` column.
#' @noRd
atima2_taxonomy <- function (taxonomy) {

  if (is.matrix(taxonomy)) taxonomy <- as.data.frame(taxonomy, stringsAsFactors = FALSE)

  if (!is.data.frame(taxonomy) || nrow(taxonomy) == 0 || ncol(taxonomy) == 0) return (NULL)

  otus     <- rownames(taxonomy)
  taxonomy <- taxonomy[, setdiff(names(taxonomy), ".otu"), drop = FALSE]

  rownames(taxonomy) <- NULL
  cbind(data.frame(.otu = otus, stringsAsFactors = FALSE), taxonomy)
}
