# A synthetic atima 2 database, built the way atima 2 itself wrote one
# (its `lib/Crypto.r`, `lib/ObjectIO.r` and `lib/UserAccounts.r`). Nothing
# here comes from a real installation: the people, addresses and passwords
# are made up, and the keys are generated when the tests run.

legacy_password <- function (who) paste0(who, "-old-password-9!")


# base64 decoding as the OpenSSL of atima 2's day did it for text that is
# not valid base64: complete groups of four characters only, and nothing at
# all if a character outside the alphabet is among them.
old_base64_decode <- function (text) {
  whole <- substr(text, 1, 4 * (nchar(text) %/% 4))
  if (grepl("[^A-Za-z0-9+/]", whole)) return (raw(0))
  openssl::base64_decode(whole)
}

old_user_key <- function (password, key_salt) {
  openssl::sha256(old_base64_decode(substr(bcrypt::hashpw(password, key_salt), 30, 61)))
}

# A key salt for which the user key comes out one way or the other:
# `dotted = TRUE` gives a hash with a '.' in its first 28 characters, for
# which the old decoder returned nothing.
old_key_salt <- function (password, dotted) {
  repeat {
    salt <- bcrypt::gensalt(4)
    text <- substr(bcrypt::hashpw(password, salt), 30, 57)
    if (grepl(".", text, fixed = TRUE) == dotted) return (salt)
  }
}

old_encode_object <- function (obj, key, long_iv = FALSE) {
  data <- openssl::aes_gcm_encrypt(memCompress(serialize(obj, NULL), type = "bzip2"), key = key, iv = openssl::rand_bytes(12))
  # Early atima 2 stored 16-byte vectors, of which only 12 were used.
  if (long_iv) attr(data, "iv") <- c(attr(data, "iv"), openssl::rand_bytes(4))
  openssl::base64_encode(serialize(data, NULL))
}


# Build the database in memory and return its connection (an RSQLite one
# standing in for MariaDB; the table and column names are atima 2's).
#
# Accounts: ada (2 projects of her own), grace (views ada's "Gut study",
# owns one), dot (her user key is the "nothing decoded" kind), and atima 2's
# two built-in accounts without an email address.
# Projects: 11 "Gut study" (ada edits, grace views; metadata edited after
# upload), 12 "Fractions" (ada; counts are not whole numbers), 13 "Soil"
# (grace), 14 "Example" (public: user 1 and everyone else may view),
# 15 (ada's, deleted), 16 "Dot's" (dot), 17 "Broken" (ada; damaged data).
local_atima2_db <- function (env = parent.frame()) {

  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  withr::defer(DBI::dbDisconnect(con), envir = env)

  for (sql in c(
    "CREATE TABLE `Users` (`UserID` INTEGER PRIMARY KEY, `Full Name` TEXT, `Affiliation` TEXT, `Email Address` TEXT,
       `Hashed Password` TEXT, `User Key Salt` TEXT, `Public Key` TEXT, `Private Key` TEXT, `Modified` TEXT)",
    "CREATE TABLE `Projects` (`ProjectID` INTEGER PRIMARY KEY, `Encryption IV` TEXT, `Key Check` TEXT, `Created` TEXT,
       `Created By` INTEGER, `Deleted` TEXT, `Deleted By` INTEGER)",
    "CREATE TABLE `Objects` (`ObjectID` INTEGER PRIMARY KEY, `ProjectID` INTEGER, `Object Name` TEXT, `Primary` INTEGER,
       `md5sum` TEXT, `Access Count` INTEGER, `Last Access` TEXT, `Base64` TEXT, `Modified` TEXT, `Modified By` INTEGER)",
    "CREATE TABLE `Permissions` (`UserID` INTEGER, `ProjectID` INTEGER, `Editor` INTEGER, `Access Count` INTEGER,
       `Last Access` TEXT, `Encryption Key` TEXT, `Modified` TEXT, `Modified By` INTEGER)",
    "CREATE TABLE `Tokens` (`UserID` INTEGER, `Token MD5` TEXT, `User Key` TEXT)" ))
    DBI::dbExecute(con, sql)

  users <- list()

  add_user <- function (id, name, email = NULL, dotted = FALSE) {

    password <- legacy_password(name)
    key_salt <- old_key_salt(password, dotted)
    user_key <- old_user_key(password, key_salt)
    private  <- openssl::rsa_keygen()

    users[[name]] <<- list(id = id, public = as.list(private)$pubkey)

    DBI::dbExecute(
      con,
      "INSERT INTO `Users` (`UserID`, `Full Name`, `Affiliation`, `Email Address`, `Hashed Password`, `User Key Salt`, `Public Key`, `Private Key`)
       VALUES (?, ?, 'Analytical Engines', ?, ?, ?, ?, ?)",
      params = list(
        id, paste(name, "Example"), if (is.null(email)) NA else email,
        bcrypt::hashpw(password, bcrypt::gensalt(4)), key_salt,
        openssl::base64_encode(serialize(as.list(private)$pubkey, NULL)),
        openssl::base64_encode(serialize(openssl::aes_gcm_encrypt(serialize(private, NULL), key = user_key, iv = openssl::rand_bytes(12)), NULL)) ))
  }

  add_user(1,   "default")
  add_user(2,   "examples")
  add_user(101, "ada",   "Ada@Example.org")
  add_user(102, "grace", "grace@example.org")
  add_user(103, "dot",   "dot@example.org", dotted = TRUE)

  add_project <- function (id, objects, editors, viewers = character(0), created = "2021-03-04 05:06:07", deleted = FALSE, long_iv = FALSE) {

    key <- openssl::aes_keygen(16)

    DBI::dbExecute(
      con, "INSERT INTO `Projects` (`ProjectID`, `Encryption IV`, `Key Check`, `Created`, `Created By`, `Deleted`) VALUES (?, '', '', ?, ?, ?)",
      params = list(id, created, users[[editors[[1]]]]$id, if (deleted) "2022-01-01 00:00:00" else NA) )

    for (who in c(editors, viewers))
      DBI::dbExecute(
        con, "INSERT INTO `Permissions` (`UserID`, `ProjectID`, `Editor`, `Encryption Key`) VALUES (?, ?, ?, ?)",
        params = list(
          users[[who]]$id, id, as.integer(who %in% editors),
          openssl::base64_encode(openssl::rsa_encrypt(serialize(key, NULL), users[[who]]$public)) ))

    for (name in names(objects)) {
      base64 <- old_encode_object(objects[[name]], key, long_iv = long_iv)
      DBI::dbExecute(
        con, "INSERT INTO `Objects` (`ProjectID`, `Object Name`, `Primary`, `md5sum`, `Base64`) VALUES (?, ?, 1, ?, ?)",
        params = list(id, name, as.character(openssl::md5(base64)), base64) )
    }
  }

  biom <- rbiom::hmp50
  file <- withr::local_tempfile(fileext = ".biom", .local_envir = env)
  rbiom::write_biom(biom, file)
  data <- readBin(file, "raw", file.size(file))

  # What atima 2 kept beside the file: a metadata table with a SampleID
  # column, factors and dates (here with a column added after upload), a
  # character matrix of taxonomy, and the tree.
  metadata <- as.data.frame(biom$metadata)
  metadata <- data.frame(
    check.names = FALSE, stringsAsFactors = TRUE,
    SampleID  = metadata$.sample,
    Age       = metadata$Age,
    `Body Site` = metadata$`Body Site`,
    Edited    = rep(c("yes", "no"), length.out = nrow(metadata)),
    Collected = as.Date("2020-01-01") + seq_len(nrow(metadata)) )
  rownames(metadata) <- metadata$SampleID

  taxonomy <- as.data.frame(biom$taxonomy)
  taxonomy <- structure(as.matrix(taxonomy[, -1]), dimnames = list(taxonomy$.otu, names(taxonomy)[-1]))

  full <- list(
    'Biom Data' = data, 'Metadata' = metadata, 'Taxonomy' = taxonomy, 'Tree' = biom$tree,
    'Project Name' = "Gut study", 'Rarefaction Level' = 1200, 'OTU Counts' = "a cache atima 2 kept; not imported" )

  # Relative abundances, as text: early atima 2 stored the file as a string.
  fractions <- rbiom::as_rbiom(file)
  fractions$counts <- fractions$counts / 4
  ffile <- withr::local_tempfile(fileext = ".biom", .local_envir = env)
  rbiom::write_biom(fractions, ffile)

  add_project(11, full, editors = "ada", viewers = "grace", long_iv = TRUE)
  add_project(12, list('Biom Data' = paste(readLines(ffile, warn = FALSE), collapse = "\n"), 'Project Name' = "Fractions", 'Tree' = NA), editors = "ada", created = "2020-02-02 02:02:02")
  add_project(13, list('Biom Data' = data, 'Project Name' = "Soil"), editors = "grace")
  add_project(14, list('Biom Data' = data, 'Project Name' = "Example"), editors = "examples", viewers = c("default", "ada", "grace", "dot"))
  add_project(15, list('Biom Data' = data, 'Project Name' = "Deleted"), editors = "ada", deleted = TRUE)
  add_project(16, list('Biom Data' = data, 'Project Name' = "Dot's"), editors = "dot")
  add_project(17, list('Biom Data' = data, 'Project Name' = "Broken"), editors = "ada", created = "2019-01-01 01:01:01")

  DBI::dbExecute(con, "UPDATE `Objects` SET `md5sum` = 'not-the-checksum' WHERE `ProjectID` = 17 AND `Object Name` = 'Biom Data'")
  DBI::dbExecute(con, "INSERT INTO `Tokens` VALUES (101, 'md5', 'a user key that must not be copied')")

  con
}


# The synthetic database, converted, as a legacy source. Building it takes
# a few seconds (five RSA key pairs), so one file serves a whole test file.
local_legacy_file <- function (env = parent.frame()) {

  testthat::skip_if_not_installed("bcrypt")

  con  <- local_atima2_db(env)
  file <- withr::local_tempfile(fileext = ".sqlite", .local_envir = env)

  suppressMessages(legacy_convert(con, file))

  file
}


# A test REQ whose configuration names the legacy file, a signed-in user
# with an open (placeholder) project, and a function that posts as them.
local_legacy_app <- function (file, env = parent.frame(), pool = NULL) {

  REQ <- local_test_req(env)
  REQ$CONFIG$legacy <- legacy_register(legacy_setting(c("Old ATIMA" = file)))

  local_fake_biom(env)

  sign_in <- function (name, is_guest = FALSE) {
    user_id <- add_test_user(REQ$DB, name, is_guest = is_guest)
    project <- add_test_project(REQ$DB, user_id, title = paste(name, "placeholder"))
    session <- add_test_session(REQ$DB, user_id, project$project_id)
    list(
      user_id = user_id,
      session = session,
      post    = function (path, args = list()) {
        out <- handle_request(fake_request("POST", path, args, session), test_app(REQ, pool))
        if (promises::is.promise(out)) out <- await(out)$value
        out
      })
  }

  list(REQ = REQ, DB = REQ$DB, source = names(REQ$CONFIG$legacy)[[1]], sign_in = sign_in)
}
