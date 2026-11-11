-- Schema version 4.
--
--  * Users are identified by an OpenID Connect identity, (issuer, sub).
--    Passwords, password resets and lockouts are gone. Accounts that were
--    made with a password keep their row, their projects and their grants,
--    but have no identity, so nobody can sign in as them until the account
--    is claimed (legacy import). The password hashes survive only in the
--    backup taken before this upgrade.
--  * Two users may now share an email address (two identities of the same
--    person), so the unique index on email becomes an ordinary one.
--  * Auth tokens expire. Tokens of password accounts are revoked.
--  * A project has two keys. `access_key` is always random and works as a
--    private share link. `public_key` is optional, short and readable; a
--    project is public exactly when it has one. This replaces `is_public`.
--    Public projects keep their address as the public key and get a new
--    private key. Private projects whose key is shorter than 12 characters
--    (chosen by a user, so guessable) get a new one.


-- users ----------------------------------------------------------------------

DROP INDEX users_idx1;

ALTER TABLE users DROP COLUMN password;
ALTER TABLE users DROP COLUMN alt_password;
ALTER TABLE users DROP COLUMN n_attempts;
ALTER TABLE users DROP COLUMN locked_utc;

ALTER TABLE users ADD COLUMN issuer TEXT NULL DEFAULT NULL;
ALTER TABLE users ADD COLUMN sub    TEXT NULL DEFAULT NULL;

CREATE UNIQUE INDEX users_identity ON users (issuer, sub);
CREATE        INDEX users_email    ON users (email);


-- auth_tokens ----------------------------------------------------------------

UPDATE sessions
   SET logout_utc = CURRENT_TIMESTAMP, auth_token_id = NULL
 WHERE auth_token_id IN (
   SELECT auth_token_id FROM auth_tokens
    WHERE user_id IN (SELECT user_id FROM users WHERE is_guest = 0));

DELETE FROM auth_tokens
 WHERE user_id IN (SELECT user_id FROM users WHERE is_guest = 0);

ALTER TABLE auth_tokens ADD COLUMN expires_utc DATETIME NULL DEFAULT NULL;

UPDATE auth_tokens SET expires_utc = datetime('now', '+30 days');

CREATE INDEX auth_tokens_expires ON auth_tokens (expires_utc);


-- projects -------------------------------------------------------------------

ALTER TABLE projects ADD COLUMN public_key TEXT NULL DEFAULT NULL;

UPDATE projects SET public_key = access_key WHERE is_public = 1;

UPDATE projects
   SET access_key =
       substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
    || substr('abcdefghijklmnopqrstuvwxyz0123456789', 1 + (random() & 2147483647) % 36, 1)
 WHERE is_public = 1 OR length(access_key) < 12;

DROP INDEX projects_is_public;

ALTER TABLE projects DROP COLUMN is_public;

CREATE UNIQUE INDEX projects_public_key ON projects (public_key);
