-- Schema version 3.
--
--  * users.seen_utc records when a user last had an active session. The
--    cleanup timer uses it to remove guests who have not come back. Existing
--    users count as seen at the time of the upgrade.

ALTER TABLE users ADD COLUMN seen_utc DATETIME NULL DEFAULT NULL;

UPDATE users SET seen_utc = CURRENT_TIMESTAMP;

CREATE INDEX users_guest_seen ON users (is_guest, seen_utc);
