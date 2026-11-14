# A stand-in OpenID Connect provider, for trying sign-in on a test server
# and for load tests. It signs anyone in as whoever they say they are, so it
# must never be reachable from outside a test machine, and atima must never
# be pointed at it on a server that holds real data.
#
#   Rscript loadtest/mock-issuer.R
#
# Settings, as environment variables:
#   MOCK_ISSUER   the URL atima and the browser both reach this server at
#                 (default http://localhost:9000). atima only accepts a
#                 provider over https or at a localhost address.
#   MOCK_PORT     port to listen on (default 9000)
#   MOCK_DELAY    seconds to wait before answering the token endpoint, to
#                 play a slow provider (default 0)
#
# The authorization endpoint shows a form that asks for a name. With
# `&as=<name>` added to its URL it skips the form, which is how a script
# signs in. The same name is always the same person (`sub`).

issuer <- sub("/+$", "", Sys.getenv("MOCK_ISSUER", "http://localhost:9000"))
port   <- as.integer(Sys.getenv("MOCK_PORT", "9000"))
delay  <- as.numeric(Sys.getenv("MOCK_DELAY", "0"))

key   <- openssl::rsa_keygen(2048)
kid   <- "mock-key-1"
codes <- new.env()

json <- function (body, status = 200L) list(
  status  = status,
  headers = list('Content-Type' = "application/json", 'Cache-Control' = "no-store"),
  body    = as.character(jsonlite::toJSON(body, auto_unbox = TRUE)) )

html <- function (body, status = 200L) list(
  status = status, headers = list('Content-Type' = "text/html; charset=utf-8"), body = body )

escape <- function (x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub('"', "&quot;", x, fixed = TRUE)
}

parse_query <- function (text) {
  text <- sub("^\\?", "", text)
  if (!nzchar(text)) return (list())
  pairs <- strsplit(strsplit(text, "&", fixed = TRUE)[[1]], "=", fixed = TRUE)
  stats::setNames(
    lapply(pairs, function (p) utils::URLdecode(gsub("+", " ", if (length(p) > 1) p[[2]] else "", fixed = TRUE))),
    vapply(pairs, function (p) utils::URLdecode(p[[1]]), character(1)) )
}

random <- function (n = 24) paste(sample(c(letters, 0:9), n, replace = TRUE), collapse = "")


authorize <- function (query) {

  if (is.null(query$redirect_uri) || is.null(query$state))
    return (html("<p>This is a mock sign-in provider. It expects a request from atima.</p>", 400L))

  # Ask who to sign in as, unless the URL says.
  if (is.null(query$as) || !nzchar(query$as)) {
    hidden <- paste0(collapse = "\n", sprintf(
      '<input type="hidden" name="%s" value="%s">', escape(names(query)), escape(unlist(query)) ))
    return (html(paste0(
      "<!doctype html><title>Mock sign-in</title>",
      "<h1>Mock sign-in provider</h1>",
      "<p>For testing only. Type any name; the same name is always the same person.</p>",
      '<form method="get" action="/authorize">', hidden,
      '<input name="as" value="Ada Lovelace" autofocus> <button>Sign in</button></form>' )))
  }

  code <- random(32)
  codes[[code]] <- query

  list(status = 302L, headers = list(Location = paste0(
    query$redirect_uri, "?code=", code, "&state=", utils::URLencode(query$state, reserved = TRUE) )), body = "")
}


token <- function (form) {

  asked <- if (!is.null(form$code) && exists(form$code, envir = codes, inherits = FALSE)) get(form$code, envir = codes)
  if (is.null(asked)) return (json(list(error = "invalid_grant"), 400L))
  rm(list = form$code, envir = codes)

  challenge <- jose::base64url_encode(openssl::sha256(charToRaw(form$code_verifier %||% "")))
  if (!identical(challenge, asked$code_challenge))
    return (json(list(error = "invalid_grant"), 400L))

  name <- asked$as
  slug <- gsub("[^a-z0-9]+", "-", tolower(name))

  claim <- jose::jwt_claim(
    iss   = issuer,
    aud   = asked$client_id,
    sub   = paste0("mock-", slug),
    exp   = Sys.time() + 300,
    iat   = Sys.time(),
    nonce = asked$nonce,
    name  = name,
    email = paste0(slug, "@mock.example"),
    organization = "Mock University" )

  json(list(
    access_token = random(32),
    token_type   = "Bearer",
    id_token     = jose::jwt_encode_sig(claim, key, size = 256, header = list(kid = kid)) ))
}


app <- list(call = function (req) {

  path  <- req$PATH_INFO
  query <- parse_query(req$QUERY_STRING)

  if (path == "/.well-known/openid-configuration")
    return (json(list(
      issuer                                = issuer,
      authorization_endpoint                = paste0(issuer, "/authorize"),
      token_endpoint                        = paste0(issuer, "/token"),
      jwks_uri                              = paste0(issuer, "/jwks"),
      scopes_supported                      = list("openid", "profile", "email"),
      id_token_signing_alg_values_supported = list("RS256"),
      token_endpoint_auth_methods_supported = list("client_secret_basic", "client_secret_post") )))

  if (path == "/jwks") {
    jwk <- jsonlite::fromJSON(jose::write_jwk(key$pubkey))
    return (json(list(keys = list(c(jwk, list(kid = kid, use = "sig", alg = "RS256"))))))
  }

  if (path == "/authorize")
    return (authorize(query))

  if (path == "/token" && req$REQUEST_METHOD == "POST") {
    form <- parse_query(rawToChar(req$rook.input$read()))
    # A slow provider, without holding up this server's other answers.
    return (promises::promise(function (resolve, reject) {
      later::later(function () resolve(token(form)), delay)
    }))
  }

  json(list(error = "not_found"), 404L)
})

`%||%` <- function (x, y) if (is.null(x)) y else x

message("Mock sign-in provider at ", issuer, " (port ", port, ", token delay ", delay, " s). For testing only.")
httpuv::runServer("0.0.0.0", port, app)
