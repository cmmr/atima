# Helpers for talking to the MCP endpoint the way a client does.


mcp_version <- "2026-07-28"

# `{}` in JSON.
json_empty <- function () structure(list(), names = character(0))

# The `_meta` every request carries.
mcp_request_meta <- function (version = mcp_version) {
  list(
    "io.modelcontextprotocol/protocolVersion"    = version,
    "io.modelcontextprotocol/clientInfo"         = list(name = "atima-tests", version = "1.0"),
    "io.modelcontextprotocol/clientCapabilities" = json_empty() )
}


# A POST to /mcp as httpuv would hand it to the app.
#   body     a list (sent as JSON) or a string (sent as it is)
#   headers  a named character vector; names in lower case, as httpuv gives them
mcp_http <- function (body, headers = character(0), host = "127.0.0.1:8080") {

  if (is.list(body))
    body <- as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null", digits = NA))

  request <- fake_request("POST", "/mcp", charToRaw(enc2utf8(body)))
  request$HEADERS   <- headers
  request$HTTP_HOST <- host
  request
}


# A well-formed MCP request: the body and the headers that repeat it.
mcp_request <- function (method, params = list(), id = 1L, version = mcp_version) {

  params$`_meta` <- mcp_request_meta(version)

  headers <- c("mcp-protocol-version" = version, "mcp-method" = method)
  if (method == "tools/call") headers[["mcp-name"]] <- params$name

  mcp_http(list(jsonrpc = "2.0", id = id, method = method, params = params), headers)
}


# A server without accounts, with the two example projects, and functions
# that make requests to its MCP endpoint. Jobs run in the test process.
local_mcp <- function (env = parent.frame()) {

  testthat::skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req(env, auth = "none")
  REQ$CONFIG$base_url <- "http://127.0.0.1:8080"

  db_seed(REQ$DB, REQ$CONFIG)

  app <- test_app(REQ)

  send <- function (request) handle_request(request, app)

  list(
    REQ  = REQ,
    DB   = REQ$DB,
    app  = app,
    send = send,
    # A request for `method`; returns the response.
    rpc  = function (method, params = list(), ...) send(mcp_request(method, params, ...)),
    # A tool call; returns the JSON-RPC result (or stops if there is none).
    call = function (name, arguments = json_empty(), ...) {
      resp <- send(mcp_request("tools/call", list(name = name, arguments = arguments), ...))
      body <- response_json(resp)
      if (is.null(body$result)) stop("tools/call failed: ", resp$status, " ", resp$body)
      body$result
    },
    temp = file.path(REQ$CONFIG$temp_dir, "mcp") )
}


# The file a URL in a tool result points to.
mcp_file <- function (mcp, url) {
  expect_match(url, "^http://127\\.0\\.0\\.1:8080/tmp/mcp/[A-Za-z0-9]{24}/[A-Za-z0-9_.-]+$")
  file.path(mcp$REQ$CONFIG$temp_dir, sub("^http://127\\.0\\.0\\.1:8080/tmp/", "", url))
}


# A JSON Schema validator, or a skip if there is none to be had.
schema_validator <- function (schema) {
  testthat::skip_if_not_installed("jsonvalidate")
  json <- jsonlite::toJSON(schema, auto_unbox = TRUE, null = "null", digits = NA)
  jsonvalidate::json_schema$new(json, engine = "ajv")
}

to_json <- function (x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = NA))
