-- Schema version 5.
--
--  * "Save a copy" used to write the copy's creation date as a number of
--    seconds instead of text such as '2026-11-12 22:30:00'. A project with
--    such a date could not be listed, so its owner could no longer load
--    the app. Those dates are rewritten as text. Nothing else changes.

UPDATE projects SET created_utc = datetime(created_utc, 'unixepoch') WHERE typeof(created_utc) IN ('integer', 'real');
