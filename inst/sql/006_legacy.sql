-- Schema version 6.
--
--  * legacy_imports records which project of an older atima's database
--    became which project here, so that importing it again makes no second
--    copy, and so that another person who could open the old project is
--    added to the same new one. `source` is the id that legacy_convert()
--    wrote into the converted file; `old_project` is the project's id in
--    the old database. The row goes when the project does.
--  * legacy_attempts holds one row per check of an old email address and
--    password that has not (yet) succeeded, to limit guessing. `subject`
--    is 'user:<user_id>' for the person who tried, or 'account:<hash>' for
--    the old account they tried; the hash is a SHA-256 of the source id
--    and the email address. No email address or password is stored.

CREATE TABLE legacy_imports (
  legacy_import_id INTEGER  PRIMARY KEY,
  source           TEXT     NOT NULL,
  old_project      TEXT     NOT NULL,
  project_id       INTEGER  NOT NULL,
  user_id          INTEGER      NULL DEFAULT NULL,
  imported_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (project_id) REFERENCES projects (project_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)    REFERENCES users    (user_id)    ON DELETE SET NULL
);

CREATE UNIQUE INDEX legacy_imports_source  ON legacy_imports (source, old_project);
CREATE        INDEX legacy_imports_project ON legacy_imports (project_id);
CREATE        INDEX legacy_imports_user    ON legacy_imports (user_id);

CREATE TABLE legacy_attempts (
  legacy_attempt_id INTEGER  PRIMARY KEY,
  subject           TEXT     NOT NULL,
  attempt_utc       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX legacy_attempts_subject ON legacy_attempts (subject, attempt_utc);
