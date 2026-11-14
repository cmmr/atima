-- Schema version 7.
--
--  * A deleted project is kept for a while before it is erased, so that it
--    can be restored. `projects.deleted_utc` says when it was deleted; a
--    project with a date there is treated everywhere as if it did not
--    exist, except by the routes that list and restore deleted projects.
--    Its grants stay, so restoring it gives everyone back what they had.
--  * app_grants holds one row per AI app that a person has connected to
--    their account (`R/oauth.R`): which app, what it may do (`scope`), and
--    until when the connection lasts if it is not used. Disconnecting an
--    app deletes the row, and its tokens with it.
--  * app_tokens holds the tokens of a connection, as SHA-256 only: access
--    tokens, which an app sends with every request to /mcp, and refresh
--    tokens, with which it gets the next access token. A refresh token
--    that has been used keeps its row, with `replaced_utc` set, so that a
--    second use of it can be recognised.
--  * app_changes is the record of every change made through a tool an AI
--    app called: who, through which app, which tool, which project, and
--    one sentence saying what changed. It holds no data from a project
--    other than its title.
--  * app_uploads holds the one-use tickets with which a file is sent to
--    the server for a tool call (`POST /api/upload`), as SHA-256 only.


-- projects -------------------------------------------------------------------

ALTER TABLE projects ADD COLUMN deleted_utc DATETIME NULL DEFAULT NULL;

CREATE INDEX projects_deleted ON projects (deleted_utc);


-- app_grants -----------------------------------------------------------------

CREATE TABLE app_grants (
  grant_id      INTEGER  PRIMARY KEY,
  user_id       INTEGER  NOT NULL,
  client_id     TEXT     NOT NULL,
  client_name   TEXT     NOT NULL,
  redirect_host TEXT     NOT NULL,
  scope         TEXT     NOT NULL,
  resource      TEXT     NOT NULL,
  created_utc   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  used_utc      DATETIME     NULL DEFAULT NULL,
  expires_utc   DATETIME NOT NULL,

  FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE
);

CREATE INDEX app_grants_user    ON app_grants (user_id);
CREATE INDEX app_grants_expires ON app_grants (expires_utc);


-- app_tokens -----------------------------------------------------------------

CREATE TABLE app_tokens (
  token_id     INTEGER  PRIMARY KEY,
  grant_id     INTEGER  NOT NULL,
  kind         TEXT     NOT NULL,
  token_sha    TEXT     NOT NULL,
  expires_utc  DATETIME NOT NULL,
  replaced_utc DATETIME     NULL DEFAULT NULL,

  FOREIGN KEY (grant_id) REFERENCES app_grants (grant_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX app_tokens_sha     ON app_tokens (token_sha);
CREATE        INDEX app_tokens_grant   ON app_tokens (grant_id);
CREATE        INDEX app_tokens_expires ON app_tokens (expires_utc);


-- app_changes ----------------------------------------------------------------

CREATE TABLE app_changes (
  change_id     INTEGER  PRIMARY KEY,
  user_id       INTEGER  NOT NULL,
  grant_id      INTEGER      NULL DEFAULT NULL,
  app           TEXT     NOT NULL,
  tool          TEXT     NOT NULL,
  project_id    INTEGER      NULL DEFAULT NULL,
  project_title TEXT         NULL DEFAULT NULL,
  summary       TEXT     NOT NULL,
  made_utc      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (user_id)  REFERENCES users      (user_id)  ON DELETE CASCADE,
  FOREIGN KEY (grant_id) REFERENCES app_grants (grant_id) ON DELETE SET NULL
);

CREATE INDEX app_changes_user  ON app_changes (user_id, made_utc);
CREATE INDEX app_changes_grant ON app_changes (grant_id, made_utc);


-- app_uploads ----------------------------------------------------------------

CREATE TABLE app_uploads (
  upload_id         INTEGER  PRIMARY KEY,
  user_id           INTEGER  NOT NULL,
  grant_id          INTEGER      NULL DEFAULT NULL,
  app               TEXT     NOT NULL,
  ticket_sha        TEXT     NOT NULL,
  what              TEXT     NOT NULL,
  project_id        INTEGER      NULL DEFAULT NULL,
  title             TEXT         NULL DEFAULT NULL,
  inflate           BOOLEAN  NOT NULL DEFAULT 0,
  state             TEXT     NOT NULL DEFAULT 'waiting',
  message           TEXT         NULL DEFAULT NULL,
  result_project_id INTEGER      NULL DEFAULT NULL,
  created_utc       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_utc       DATETIME NOT NULL,

  FOREIGN KEY (user_id)    REFERENCES users      (user_id)    ON DELETE CASCADE,
  FOREIGN KEY (grant_id)   REFERENCES app_grants (grant_id)   ON DELETE CASCADE,
  FOREIGN KEY (project_id) REFERENCES projects   (project_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX app_uploads_ticket  ON app_uploads (ticket_sha);
CREATE        INDEX app_uploads_user    ON app_uploads (user_id);
CREATE        INDEX app_uploads_grant   ON app_uploads (grant_id);
CREATE        INDEX app_uploads_project ON app_uploads (project_id);
CREATE        INDEX app_uploads_expires ON app_uploads (expires_utc);
