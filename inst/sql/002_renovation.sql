-- Schema version 2.
--
--  * Public projects are marked on the project (is_public, and
--    public_collection_id for their place in the public tree) instead of by
--    a permission row owned by "user 0". Public collections have a NULL
--    user_id instead of user_id 0.
--  * The placeholder rows are removed: users 0 and 1000, project 10000 and
--    biom file 0.
--  * The migration_* tables, which held atima 2 data waiting to be claimed,
--    are dropped. (The database is backed up before any upgrade.)
--  * Every foreign key gets an ON DELETE rule, and foreign key columns get
--    indexes.
--
-- SQLite cannot alter a foreign key in place, so each table that has one is
-- rebuilt: create new_<table>, copy the rows, drop the old table, rename.
-- The migration runner switches foreign key enforcement off while this runs
-- and checks every key before it commits. Rows that point at something that
-- no longer exists (possible in 5.0.x, which never enforced foreign keys)
-- are dropped, or have the dangling column set to NULL where it is nullable.


-- Leftovers ------------------------------------------------------------------

DROP TABLE IF EXISTS migration_user_keys;
DROP TABLE IF EXISTS migration_perm_keys;
DROP TABLE IF EXISTS migration_objects;

DELETE FROM users      WHERE user_id = 0    AND full_name = 'atima'  AND email IS NULL;
DELETE FROM users      WHERE user_id = 1000 AND full_name = 'atima2' AND email IS NULL;
DELETE FROM biom_files WHERE biom_file_id = 0 AND file = '';


-- collections ----------------------------------------------------------------

CREATE TABLE new_collections (
  collection_id        INTEGER PRIMARY KEY,
  user_id              INTEGER     NULL DEFAULT NULL
    REFERENCES users (user_id) ON DELETE CASCADE,
  parent_collection_id INTEGER     NULL DEFAULT NULL
    REFERENCES collections (collection_id) ON DELETE CASCADE,
  jstree_text          TEXT    NOT NULL,
  jstree_icon          TEXT    NOT NULL DEFAULT ''
);

INSERT INTO new_collections
  (collection_id, user_id, parent_collection_id, jstree_text, jstree_icon)
SELECT
  c.collection_id,
  NULLIF(c.user_id, 0),
  (SELECT p.collection_id FROM collections p WHERE p.collection_id = c.parent_collection_id),
  c.jstree_text,
  c.jstree_icon
FROM collections c
WHERE c.user_id IS NULL OR c.user_id = 0
   OR c.user_id IN (SELECT user_id FROM users);

DROP TABLE collections;
ALTER TABLE new_collections RENAME TO collections;

CREATE INDEX collections_user_id ON collections (user_id);
CREATE INDEX collections_parent  ON collections (parent_collection_id);


-- projects -------------------------------------------------------------------

CREATE TABLE new_projects (
  project_id    INTEGER  PRIMARY KEY,
  title         TEXT     NOT NULL,
  orig_bf_id    INTEGER  NOT NULL
    REFERENCES biom_files (biom_file_id) ON DELETE RESTRICT,
  full_bf_id    INTEGER  NOT NULL
    REFERENCES biom_files (biom_file_id) ON DELETE RESTRICT,
  rare_bf_id    INTEGER  NOT NULL
    REFERENCES biom_files (biom_file_id) ON DELETE RESTRICT,
  access_key    TEXT     NOT NULL,
  description   TEXT     NOT NULL DEFAULT '',
  selections    TEXT     NOT NULL DEFAULT '{}',
  n_samples     INTEGER  NOT NULL DEFAULT 0,
  n_taxa        INTEGER  NOT NULL DEFAULT 0,
  has_tree      INTEGER  NOT NULL DEFAULT 0,
  median_depth  INTEGER  NOT NULL DEFAULT 0,
  meta_colnames TEXT     NOT NULL DEFAULT '[]',
  editors       TEXT     NOT NULL DEFAULT '[]',
  n_views       INTEGER  NOT NULL DEFAULT 0,
  jstree_icon   TEXT     NOT NULL DEFAULT '',
  created_utc   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_public     INTEGER  NOT NULL DEFAULT 0,
  public_collection_id INTEGER NULL DEFAULT NULL
    REFERENCES collections (collection_id) ON DELETE SET NULL
);

INSERT INTO new_projects (
  project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key,
  description, selections, n_samples, n_taxa, has_tree, median_depth,
  meta_colnames, editors, n_views, jstree_icon, created_utc,
  is_public, public_collection_id )
SELECT
  p.project_id, p.title, p.orig_bf_id, p.full_bf_id, p.rare_bf_id, p.access_key,
  p.description, p.selections, p.n_samples, p.n_taxa, p.has_tree, p.median_depth,
  p.meta_colnames, p.editors, p.n_views, p.jstree_icon, p.created_utc,
  pub.permission_id IS NOT NULL,
  (SELECT c.collection_id FROM collections c
    WHERE c.collection_id = pub.collection_id AND c.user_id IS NULL)
FROM projects p
  LEFT JOIN permissions pub ON pub.project_id = p.project_id AND pub.user_id = 0
WHERE NOT (p.project_id = 10000 AND p.access_key = '');

DROP TABLE projects;
ALTER TABLE new_projects RENAME TO projects;

CREATE UNIQUE INDEX projects_access_key        ON projects (access_key);
CREATE        INDEX projects_is_public         ON projects (is_public);
CREATE        INDEX projects_public_collection ON projects (public_collection_id);


-- drafts ---------------------------------------------------------------------

CREATE TABLE new_drafts (
  draft_id    INTEGER  PRIMARY KEY,
  project_id  INTEGER  NOT NULL
    REFERENCES projects (project_id) ON DELETE CASCADE,
  full_bf_id  INTEGER  NOT NULL
    REFERENCES biom_files (biom_file_id) ON DELETE RESTRICT,
  rare_bf_id  INTEGER  NOT NULL
    REFERENCES biom_files (biom_file_id) ON DELETE RESTRICT,
  selections  TEXT     NOT NULL DEFAULT '{}'
);

INSERT INTO new_drafts (draft_id, project_id, full_bf_id, rare_bf_id, selections)
SELECT draft_id, project_id, full_bf_id, rare_bf_id, selections
FROM drafts
WHERE project_id IN (SELECT project_id   FROM projects)
  AND full_bf_id IN (SELECT biom_file_id FROM biom_files)
  AND rare_bf_id IN (SELECT biom_file_id FROM biom_files);

DROP TABLE drafts;
ALTER TABLE new_drafts RENAME TO drafts;

CREATE INDEX drafts_project_id ON drafts (project_id);


-- last_access ----------------------------------------------------------------

CREATE TABLE new_last_access (
  last_access_id INTEGER PRIMARY KEY,
  user_id        INTEGER  NOT NULL
    REFERENCES users (user_id) ON DELETE CASCADE,
  project_id     INTEGER  NOT NULL
    REFERENCES projects (project_id) ON DELETE CASCADE,
  is_starred     INTEGER  NOT NULL DEFAULT 0,
  viewed_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO new_last_access (last_access_id, user_id, project_id, is_starred, viewed_utc)
SELECT last_access_id, user_id, project_id, is_starred, viewed_utc
FROM last_access
WHERE user_id    IN (SELECT user_id    FROM users)
  AND project_id IN (SELECT project_id FROM projects);

DROP TABLE last_access;
ALTER TABLE new_last_access RENAME TO last_access;

CREATE UNIQUE INDEX last_access_user_project ON last_access (user_id, project_id);
CREATE        INDEX last_access_project_id   ON last_access (project_id);


-- permissions ----------------------------------------------------------------

CREATE TABLE new_permissions (
  permission_id   INTEGER  PRIMARY KEY,
  user_id         INTEGER  NOT NULL
    REFERENCES users (user_id) ON DELETE CASCADE,
  project_id      INTEGER  NOT NULL
    REFERENCES projects (project_id) ON DELETE CASCADE,
  collection_id   INTEGER      NULL DEFAULT NULL
    REFERENCES collections (collection_id) ON DELETE SET NULL,
  is_editor       INTEGER  NOT NULL DEFAULT 1,
  grantor_user_id INTEGER      NULL DEFAULT NULL
    REFERENCES users (user_id) ON DELETE SET NULL
);

INSERT INTO new_permissions
  (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id)
SELECT
  m.permission_id,
  m.user_id,
  m.project_id,
  (SELECT c.collection_id FROM collections c
    WHERE c.collection_id = m.collection_id AND c.user_id = m.user_id),
  m.is_editor,
  (SELECT u.user_id FROM users u WHERE u.user_id = m.grantor_user_id)
FROM permissions m
WHERE m.user_id    IN (SELECT user_id    FROM users)
  AND m.project_id IN (SELECT project_id FROM projects);

DROP TABLE permissions;
ALTER TABLE new_permissions RENAME TO permissions;

CREATE UNIQUE INDEX permissions_user_project  ON permissions (user_id, project_id);
CREATE        INDEX permissions_project_id    ON permissions (project_id);
CREATE        INDEX permissions_collection_id ON permissions (collection_id);
CREATE        INDEX permissions_grantor       ON permissions (grantor_user_id);


-- auth_tokens ----------------------------------------------------------------

CREATE TABLE new_auth_tokens (
  auth_token_id  INTEGER PRIMARY KEY,
  auth_token_sha TEXT    NOT NULL,
  user_id        INTEGER NOT NULL
    REFERENCES users (user_id) ON DELETE CASCADE
);

INSERT INTO new_auth_tokens (auth_token_id, auth_token_sha, user_id)
SELECT auth_token_id, auth_token_sha, user_id
FROM auth_tokens
WHERE user_id IN (SELECT user_id FROM users);

DROP TABLE auth_tokens;
ALTER TABLE new_auth_tokens RENAME TO auth_tokens;

CREATE UNIQUE INDEX auth_tokens_sha     ON auth_tokens (auth_token_sha);
CREATE        INDEX auth_tokens_user_id ON auth_tokens (user_id);


-- sessions -------------------------------------------------------------------

CREATE TABLE new_sessions (
  session_id    INTEGER PRIMARY KEY,
  auth_token_id INTEGER      NULL
    REFERENCES auth_tokens (auth_token_id) ON DELETE SET NULL,
  user_id       INTEGER      NULL
    REFERENCES users (user_id) ON DELETE SET NULL,
  draft_id      INTEGER      NULL
    REFERENCES drafts (draft_id) ON DELETE SET NULL,
  ip_address    TEXT     NOT NULL,
  session_key   TEXT         NULL DEFAULT NULL,
  login_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  logout_utc    DATETIME     NULL DEFAULT NULL,
  heartbeat_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO new_sessions (
  session_id, auth_token_id, user_id, draft_id, ip_address, session_key,
  login_utc, logout_utc, heartbeat_utc )
SELECT
  s.session_id,
  (SELECT a.auth_token_id FROM auth_tokens a WHERE a.auth_token_id = s.auth_token_id),
  (SELECT u.user_id       FROM users u       WHERE u.user_id       = s.user_id),
  (SELECT d.draft_id      FROM drafts d      WHERE d.draft_id      = s.draft_id),
  s.ip_address, s.session_key, s.login_utc, s.logout_utc, s.heartbeat_utc
FROM sessions s;

DROP TABLE sessions;
ALTER TABLE new_sessions RENAME TO sessions;

CREATE UNIQUE INDEX sessions_session_key   ON sessions (session_key);
CREATE        INDEX sessions_auth_token_id ON sessions (auth_token_id);
CREATE        INDEX sessions_user_id       ON sessions (user_id);
CREATE        INDEX sessions_draft_id      ON sessions (draft_id);
CREATE        INDEX sessions_heartbeat_utc ON sessions (heartbeat_utc);
