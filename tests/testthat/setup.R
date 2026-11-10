# Keep the server log out of the test output. Tests that look at the log
# point `atima.log` at a file of their own.
withr::local_options(atima.log = nullfile(), .local_envir = testthat::teardown_env())
