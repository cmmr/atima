# Text from users and uploaded files never reaches a browser as live HTML.


payloads <- c(
  '<script>alert("xss")</script>',
  '<img src=x onerror=alert(1)>',
  '"><svg onload=alert(1)>',
  "'; alert(1); '",
  '<a href="javascript:alert(1)">click</a>',
  '</th><script src=//evil.test/x.js></script>' )


test_that("html_escape escapes the five characters and keeps shape", {

  expect_identical(html_escape("<b>\"Tom\" & 'Jerry'</b>"), "&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;")
  expect_identical(html_escape("plain text 123"), "plain text 123")
  expect_identical(html_escape(c("a<b", NA, "")), c("a&lt;b", "", ""))
  expect_identical(html_escape(character(0)), character(0))
  expect_identical(html_escape(5L), "5")

  # Already-escaped text is escaped again, never unescaped.
  expect_identical(html_escape("&lt;"), "&amp;lt;")

  m <- matrix(c("<a>", "b", "c", "&"), nrow = 2, dimnames = list(NULL, c("x", "y")))
  expect_identical(html_escape(m), matrix(c("&lt;a&gt;", "b", "c", "&amp;"), nrow = 2, dimnames = list(NULL, c("x", "y"))))

  for (payload in payloads) {
    escaped <- html_escape(payload)
    expect_false(grepl("[<>\"']", escaped), info = payload)
  }
})


test_that("table headers escape column names", {

  md <- data.frame(.sample = c("S1", "S2"), check.names = FALSE, stringsAsFactors = FALSE)
  for (payload in payloads) md[[payload]] <- c("1", "2")

  for (html in list(metadata_thead(md), taxonomy_thead(md))) {

    for (payload in payloads)
      expect_false(grepl(payload, html, fixed = TRUE), info = payload)

    expect_no_match(html, "<script", fixed = TRUE)
    expect_no_match(html, "<img", fixed = TRUE)
    expect_no_match(html, "<svg", fixed = TRUE)
    expect_match(html, "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;", fixed = TRUE)

    # The only elements are the table's own.
    tags <- unique(regmatches(html, gregexpr("</?[a-zA-Z]+", html))[[1]])
    expect_true(all(tags %in% c("<thead", "</thead", "<tr", "</tr", "<th", "</th", "<td", "</td", "<select", "</select", "<option", "</option")))
  }
})


test_that("table pages escape cell values, after searching the real text", {

  df <- data.frame(
    sample = c("S1", "S2", "S3"),
    note   = c('<script>alert("xss")</script>', "Fish & Chips", "plain"),
    stringsAsFactors = FALSE )

  page <- dt_page(df)
  expect_identical(
    unname(page$data[, "note"]),
    c("&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;", "Fish &amp; Chips", "plain") )

  # Searching is done on what the user typed, not on the escaped form.
  expect_identical(dt_page(df, search = list(value = "<script>"))$recordsFiltered, jsonlite::unbox(1L))
  expect_identical(dt_page(df, search = list(value = "fish & chips"))$recordsFiltered, jsonlite::unbox(1L))
  expect_identical(dt_page(df, search = list(value = "&amp;"))$recordsFiltered, jsonlite::unbox(0L))
})


test_that("sanitize_html keeps simple formatting and removes everything that can run", {

  # Formatting survives.
  expect_identical(sanitize_html("<p>About <b>this</b> <em>study</em></p>"), "<p>About <b>this</b> <em>study</em></p>")
  expect_identical(sanitize_html("<ul><li>one</li><li>two</li></ul>"), "<ul><li>one</li><li>two</li></ul>")
  expect_identical(sanitize_html("line one<br>line two"), "line one<br>line two")
  expect_identical(sanitize_html("plain text"), "plain text")
  expect_identical(sanitize_html("5 < 6 & 7 > 2"), "5 &lt; 6 &amp; 7 &gt; 2")

  # Links keep an http(s) or mailto address and nothing else.
  expect_identical(
    sanitize_html('<a href="https://example.org/a?b=1&c=2" onclick="evil()" target="_blank">site</a>'),
    '<a href="https://example.org/a?b=1&amp;c=2" rel="noopener noreferrer nofollow">site</a>' )
  expect_identical(sanitize_html('<a href="mailto:ada@example.org">mail</a>'), '<a href="mailto:ada@example.org" rel="noopener noreferrer nofollow">mail</a>')
  for (href in c("javascript:alert(1)", "JaVaScRiPt:alert(1)", " javascript:alert(1)", "java\tscript:alert(1)", "data:text/html,<script>alert(1)</script>", "vbscript:x", "//evil.test", "/relative"))
    expect_identical(sanitize_html(sprintf('<a href="%s">x</a>', href)), "x", info = href)

  # Empty and missing values.
  for (empty in list(NULL, NA, "", "   ", character(0)))
    expect_identical(sanitize_html(empty), "")

  # Things that can run or load are gone, with their contents.
  dangerous <- c(
    '<script>alert(1)</script>',
    '<SCRIPT SRC=//evil.test/x.js></SCRIPT>',
    '<img src=x onerror=alert(1)>',
    '<svg onload=alert(1)><circle/></svg>',
    '<iframe src="javascript:alert(1)"></iframe>',
    '<style>body{background:url(javascript:alert(1))}</style>',
    '<object data="x"></object><embed src="x">',
    '<form action="//evil.test"><input name="q"><button>go</button></form>',
    '<math><mi xlink:href="javascript:alert(1)">x</mi></math>',
    '<link rel="stylesheet" href="//evil.test/x.css">',
    '<meta http-equiv="refresh" content="0;url=//evil.test">',
    '<base href="//evil.test/">',
    '<!-- comment --><!--[if IE]><script>alert(1)</script><![endif]-->' )

  for (html in dangerous)
    expect_identical(sanitize_html(html), "", info = html)

  # Attributes never survive, whatever element they are on.
  expect_identical(sanitize_html('<p style="position:fixed" onmouseover="alert(1)" class="x" id="y">hi</p>'), "<p>hi</p>")
  expect_identical(sanitize_html('<b onclick=alert(1)>bold</b>'), "<b>bold</b>")

  # Unknown elements go; their text stays, escaped.
  expect_identical(sanitize_html("<div><span>some</span> <font color=red>text</font></div>"), "some text")
  expect_identical(sanitize_html("<table><tr><td>cell</td></tr></table>"), "cell")

  # Broken and nested markup cannot smuggle anything through.
  tricky <- c(
    '<scr<script>ipt>alert(1)</scr</script>ipt>',
    '<p><script>alert(1)</p></script>',
    '<img src="x" onerror="alert(1)"',
    '<a href="https://ok.test" <script>alert(1)</script>>x</a>',
    '&lt;script&gt;alert(1)&lt;/script&gt;',
    '<p title="</p><script>alert(1)</script>">x</p>',
    '<<script>script>alert(1)<</script>/script>',
    '<noscript><p title="</noscript><img src=x onerror=alert(1)>">',
    '<svg><p><style><img src=x onerror=alert(1)></style></p></svg>',
    paste(payloads, collapse = " ") )

  for (html in tricky) {

    clean <- sanitize_html(html)

    # Parsed again, what is left has only allowed elements and attributes.
    doc   <- xml2::read_html(paste0("<div>", clean, "</div>"))
    nodes <- xml2::xml_find_all(doc, "//body/div//*")
    expect_true(all(xml2::xml_name(nodes) %in% html_allowed), info = html)

    attrs <- unlist(lapply(nodes, function (n) names(xml2::xml_attrs(n))))
    expect_true(all(attrs %in% c("href", "rel")), info = html)

    expect_no_match(clean, "<script", ignore.case = TRUE, info = html)
    expect_no_match(clean, "onerror\\s*=\\s*[\"']?alert", ignore.case = TRUE, info = html)

    # Cleaning what is already clean changes nothing.
    expect_identical(sanitize_html(clean), clean, info = html)
  }
})


test_that("a project description is sanitized by the router before a handler sees it", {

  save <- match_route("POST", "/api/project/save")$route

  args <- validate_args(save, list(
    title       = "My study",
    description = '<p onclick="steal()">About <script>alert(document.cookie)</script><b>this</b></p><img src=x onerror=alert(1)>' ))
  expect_identical(args$description, "<p>About <b>this</b></p>")

  # The same for "save as", and the length limit still holds.
  save_as <- match_route("POST", "/api/project/save_as")$route
  expect_identical(save_as$args$description$type, "html")
  expect_error(validate_args(save, list(title = "My study", description = strrep("x", 5001))), "at most 5000", class = "atima_http_error")
  expect_error(validate_args(save, list(title = "My study", description = 5)), class = "atima_http_error")

  # Every route argument that is stored and later shown as HTML is of the
  # sanitizing type.
  for (r in route_table())
    if ("description" %in% names(r$args))
      expect_identical(r$args$description$type, "html", info = r$endpoint)
})


test_that("XSS payloads in an uploaded file come back escaped from every route", {

  skip_if_not(pandoc::pandoc_available(), "pandoc is not installed")

  REQ <- local_test_req()
  DB  <- REQ$DB
  app <- test_app(REQ)
  db_seed(DB, REQ$CONFIG)

  session <- session_from(handle_request(fake_request("POST", "/api/session/init", list()), app))
  post    <- function (path, args = list()) handle_request(fake_request("POST", path, args, session), app)

  # A BIOM file whose metadata names, metadata values, taxonomy values and
  # comment all carry markup.
  evil_name  <- '<img src=x onerror=alert(1)>'
  evil_value <- '<script>alert("xss")</script>'

  biom    <- rbiom::hmp50$clone()
  md      <- biom$metadata
  md[[evil_name]] <- evil_value
  biom$metadata   <- md
  tax       <- biom$taxonomy
  tax$Genus <- paste0(tax$Genus, '<svg onload=alert(1)>')
  biom$taxonomy <- tax
  biom$comment  <- 'A study <script>alert(document.cookie)</script> with **bold** text <img src=x onerror=alert(1)>'

  file <- withr::local_tempfile(fileext = ".biom")
  rbiom::write_biom(biom, file)

  form <- multipart_body(list(biom_file = list(filename = "evil.biom", value = read_file_raw(file))))
  resp <- handle_request(fake_request("POST", "/api/project/upload", form$body, session, content_type = form$content_type), app)
  expect_identical(resp$status, 200L)

  # The description that was made from the file's comment.
  description <- response_json(resp)$BIOM$description
  expect_match(description, "bold")
  expect_no_match(description, "<script", fixed = TRUE)
  expect_no_match(description, "<img", fixed = TRUE)
  expect_no_match(description, "onerror", fixed = TRUE)
  expect_identical(db_query(DB, "SELECT description FROM projects WHERE title = 'evil'", "T1"), description)

  # Headers: the names are there, as text.
  for (path in c("/api/metadata/thead", "/api/taxonomy/thead")) {
    html <- response_json(post(path))$html
    expect_no_match(html, "<img", fixed = TRUE, info = path)
    expect_no_match(html, "<script", fixed = TRUE, info = path)
    expect_no_match(html, "<svg", fixed = TRUE, info = path)
  }
  expect_match(response_json(post("/api/metadata/thead"))$html, "&lt;img src=x onerror=alert(1)&gt;", fixed = TRUE)

  # Cells: the values are there, as text.
  cells <- unlist(response_json(post("/api/metadata/table", list(length = 100)))$data)
  expect_true("&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;" %in% cells)
  expect_false(any(grepl("[<>]", cells)))

  cells <- unlist(response_json(post("/api/taxonomy/table", list(length = 100)))$data)
  expect_true(any(grepl("&lt;svg onload=alert(1)&gt;", cells, fixed = TRUE)))
  expect_false(any(grepl("[<>]", cells)))

  # Saving a description with markup stores, and returns, the clean form.
  resp <- post("/api/project/save", list(title = "Evil study", description = paste0("<p>Notes</p>", evil_value, evil_name)))
  expect_identical(resp$status, 200L)
  expect_identical(response_json(resp)$BIOM$description, "<p>Notes</p>")
  expect_identical(db_query(DB, "SELECT description FROM projects WHERE title = 'Evil study'", "T2"), "<p>Notes</p>")

  # The copy made by "save as" gets the same treatment.
  resp <- post("/api/project/save_as", list(title = "Evil copy", description = '<a href="javascript:alert(1)">x</a><b>ok</b>'))
  expect_identical(response_json(resp)$BIOM$description, "x<b>ok</b>")
})


test_that("html_text gives a description's text without its elements", {

  expect_identical(html_text("<p>Fifty <b>samples</b> from<br>five sites.</p><ul><li>one</li></ul>"), "Fifty samples fromfive sites.one")
  expect_identical(html_text("<p>a &lt;script&gt; &amp; more</p>"), "a <script> & more")
  expect_identical(html_text("plain words"), "plain words")
  expect_identical(html_text(""), "")
  expect_identical(html_text(NA_character_), "")
  expect_identical(html_text(NULL), "")
})
