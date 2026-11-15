# Country and network lookup in MaxMind DB files (R/geo.R).


test_that("an address becomes its bits", {

  bits <- function (ip) paste(ip_bits(ip), collapse = "")

  expect_identical(bits("1.2.3.4"), "00000001000000100000001100000100")
  expect_identical(bits("255.255.255.255"), strrep("1", 32))
  expect_identical(bits("::1"), paste0(strrep("0", 127), "1"))
  expect_identical(bits("::"), strrep("0", 128))
  expect_identical(bits("2001:db8::ff"), bits("2001:0db8:0000:0000:0000:0000:0000:00ff"))
  expect_identical(bits("[2001:db8::ff]"), bits("2001:db8::ff"))
  expect_identical(bits("fe80::1%eth0"), bits("fe80::1"))
  expect_identical(substr(bits("2001:db8::"), 1, 32), "00100000000000010000110110111000")

  # An IPv4 address written as IPv6.
  expect_identical(substr(bits("::ffff:1.2.3.4"), 97, 128), bits("1.2.3.4"))
  expect_identical(substr(bits("::ffff:1.2.3.4"), 81, 96), strrep("1", 16))

  for (bad in list("", "1.2.3", "1.2.3.256", "1.2.3.4.5", "hello", "1::2::3", "12345::", "1:2:3:4:5:6:7:8:9", NA_character_, NULL, 5, c("1.2.3.4", "1.2.3.5")))
    expect_null(ip_bits(bad))
})


test_that("a database file is read: tree, records, nested values and both kinds of address", {

  path <- withr::local_tempfile(fileext = ".mmdb")

  write_test_mmdb(path, list(
    "192.0.2.0/24"   = list(country = list(iso_code = "DE", names = list(en = "Germany")), continent = list(code = "EU")),
    "198.51.100.0/25" = list(country = list(iso_code = "BR")),
    "2001:db8::/32"  = list(country = list(iso_code = "JP"), flags = list(TRUE, 70000, "x")) ))

  db <- mmdb_open(path)

  expect_identical(db$ip_version, 6)
  expect_identical(db$record_size, 24)

  expect_identical(mmdb_find(db, "192.0.2.1")$country$iso_code, "DE")
  expect_identical(mmdb_find(db, "192.0.2.255")$country$names$en, "Germany")
  expect_identical(mmdb_find(db, "192.0.2.77")$continent$code, "EU")
  expect_identical(mmdb_find(db, "198.51.100.127")$country$iso_code, "BR")
  expect_identical(mmdb_find(db, "2001:db8:1234::1")$country$iso_code, "JP")
  expect_identical(mmdb_find(db, "2001:db8::1")$flags, list(TRUE, 70000, "x"))

  # Outside every network, and not an address at all.
  expect_null(mmdb_find(db, "198.51.100.128"))
  expect_null(mmdb_find(db, "192.0.3.1"))
  expect_null(mmdb_find(db, "2001:db9::1"))
  expect_null(mmdb_find(db, "not an address"))
  expect_null(mmdb_find(db, ""))
})


test_that("a database for IPv4 only answers IPv4 addresses", {

  path <- withr::local_tempfile(fileext = ".mmdb")
  write_test_mmdb(path, list("203.0.113.0/24" = list(country_code = "IN")), version = 4L)

  db <- mmdb_open(path)

  expect_identical(mmdb_find(db, "203.0.113.9")$country_code, "IN")
  expect_identical(mmdb_find(db, "::ffff:203.0.113.9")$country_code, "IN")
  expect_null(mmdb_find(db, "2001:db8::1"))
  expect_null(mmdb_find(db, "203.0.114.9"))
})


test_that("country and network are found in files of either naming, and several files are combined", {

  countries <- withr::local_tempfile(fileext = ".mmdb")
  networks  <- withr::local_tempfile(fileext = ".mmdb")
  combined  <- withr::local_tempfile(fileext = ".mmdb")

  # The layout of DB-IP's and MaxMind's files.
  write_test_mmdb(countries, list("192.0.2.0/24" = list(country = list(iso_code = "de"))))
  write_test_mmdb(networks,  list("192.0.2.0/24" = list(autonomous_system_number = 64500, autonomous_system_organization = "Example University")))

  # The layout of IPinfo's.
  write_test_mmdb(combined, list("198.51.100.0/24" = list(country_code = "BR", as_name = "Universidade Exemplo", asn = "AS64501")))

  geo <- geo_open(c(countries, networks, combined))

  expect_identical(geo_lookup(geo, "192.0.2.10"), list(country = "DE", network = "Example University"))
  expect_identical(geo_lookup(geo, "198.51.100.10"), list(country = "BR", network = "Universidade Exemplo"))

  # Not found, not an address, no files: nothing, and no error.
  expect_identical(geo_lookup(geo, "203.0.113.1"), list())
  expect_identical(geo_lookup(geo, "garbage"), list())
  expect_identical(geo_lookup(NULL, "192.0.2.10"), list())
  expect_identical(geo_lookup(geo_open(countries), "192.0.2.10"), list(country = "DE"))
})


test_that("a file that is missing or is not a database stops with its name", {

  expect_null(geo_open(NULL))

  expect_error(geo_open("no-such-file.mmdb"), "no-such-file.mmdb could not be read")

  junk <- withr::local_tempfile(fileext = ".mmdb")
  writeBin(as.raw(1:200), junk)
  expect_error(geo_open(junk), "not a MaxMind DB file")
})


test_that("the geo_db setting is one or more paths", {

  expect_null(geo_setting(NULL))
  expect_null(geo_setting(""))
  expect_identical(geo_setting("a.mmdb"), "a.mmdb")
  expect_identical(geo_setting("a.mmdb; b.mmdb"), c("a.mmdb", "b.mmdb"))
  expect_identical(geo_setting(c("a.mmdb", "b.mmdb")), c("a.mmdb", "b.mmdb"))
  expect_error(geo_setting(5), "geo_db")
})
