-- A database as atima 5.0.x (before schema versioning) created it, with a
-- little data. Used to test the in-place upgrade.
--
-- The CREATE and first INSERT statements are copied from init_db_structure()
-- in the last pre-renovation R/database.r. Do not tidy them: the point of
-- this file is to stay exactly as old installations are.

CREATE TABLE IF NOT EXISTS users (
  user_id      INTEGER PRIMARY KEY,
  full_name    TEXT    NOT NULL DEFAULT 'Guest',
  affiliation  TEXT        NULL DEFAULT NULL,
  email        TEXT        NULL DEFAULT NULL,
  password     TEXT        NULL DEFAULT NULL,
  alt_password TEXT        NULL DEFAULT NULL,
  is_guest     INTEGER NOT NULL DEFAULT 1,
  is_admin     INTEGER NOT NULL DEFAULT 0,
  n_attempts   INTEGER NOT NULL DEFAULT 0,
  locked_utc   DATETIME    NULL DEFAULT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS users_idx1 ON users (email);
INSERT INTO users (user_id, full_name, is_guest) VALUES (0, 'atima', 0);

CREATE TABLE IF NOT EXISTS biom_files (
  biom_file_id INTEGER PRIMARY KEY,
  file         TEXT    NOT NULL,
  hash         TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS biom_files_idx1 ON biom_files (hash);
INSERT INTO biom_files (biom_file_id, file, hash) VALUES (0, '', '');

CREATE TABLE IF NOT EXISTS projects (
  project_id    INTEGER  PRIMARY KEY,
  title         TEXT     NOT NULL,
  orig_bf_id    INTEGER  NOT NULL,
  full_bf_id    INTEGER  NOT NULL,
  rare_bf_id    INTEGER  NOT NULL,
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

  FOREIGN KEY (orig_bf_id) REFERENCES biom_files (biom_file_id),
  FOREIGN KEY (full_bf_id) REFERENCES biom_files (biom_file_id),
  FOREIGN KEY (rare_bf_id) REFERENCES biom_files (biom_file_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS projects_idx1 ON projects (access_key);

CREATE TABLE IF NOT EXISTS drafts (
  draft_id    INTEGER  PRIMARY KEY,
  project_id  INTEGER  NOT NULL,
  full_bf_id  INTEGER  NOT NULL,
  rare_bf_id  INTEGER  NOT NULL,
  selections  TEXT     NOT NULL DEFAULT '{}',

  FOREIGN KEY (project_id) REFERENCES projects   (project_id),
  FOREIGN KEY (full_bf_id) REFERENCES biom_files (biom_file_id),
  FOREIGN KEY (rare_bf_id) REFERENCES biom_files (biom_file_id)
);

CREATE TABLE IF NOT EXISTS last_access (
  last_access_id INTEGER PRIMARY KEY,
  user_id        INTEGER  NOT NULL,
  project_id     INTEGER  NOT NULL,
  is_starred     INTEGER  NOT NULL DEFAULT 0,
  viewed_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (user_id)    REFERENCES users    (user_id),
  FOREIGN KEY (project_id) REFERENCES projects (project_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS last_access_idx1 ON last_access (user_id, project_id);

CREATE TABLE IF NOT EXISTS permissions (
  permission_id   INTEGER  PRIMARY KEY,
  user_id         INTEGER  NOT NULL,
  project_id      INTEGER  NOT NULL,
  collection_id   INTEGER      NULL DEFAULT NULL,
  is_editor       INTEGER  NOT NULL DEFAULT 1,
  grantor_user_id INTEGER      NULL DEFAULT NULL,

  FOREIGN KEY (user_id)         REFERENCES users       (user_id),
  FOREIGN KEY (grantor_user_id) REFERENCES users       (user_id),
  FOREIGN KEY (project_id)      REFERENCES projects    (project_id),
  FOREIGN KEY (collection_id)   REFERENCES collections (collection_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS permissions_idx1 ON permissions (user_id, project_id);
CREATE        INDEX IF NOT EXISTS permissions_idx2 ON permissions (collection_id);

CREATE TABLE IF NOT EXISTS collections (
  collection_id        INTEGER PRIMARY KEY,
  user_id              INTEGER     NULL DEFAULT NULL,
  parent_collection_id INTEGER     NULL DEFAULT NULL,
  jstree_text          TEXT    NOT NULL,
  jstree_icon          TEXT    NOT NULL DEFAULT '',

  FOREIGN KEY (user_id)              REFERENCES users       (user_id),
  FOREIGN KEY (parent_collection_id) REFERENCES collections (collection_id)
);

CREATE TABLE IF NOT EXISTS auth_tokens (
  auth_token_id  INTEGER PRIMARY KEY,
  auth_token_sha TEXT    NOT NULL,
  user_id        INTEGER NOT NULL,

  FOREIGN KEY (user_id) REFERENCES users (user_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS auth_tokens_idx1 ON auth_tokens (auth_token_sha);

CREATE TABLE IF NOT EXISTS sessions (
  session_id    INTEGER PRIMARY KEY,
  auth_token_id INTEGER      NULL,
  user_id       INTEGER      NULL,
  draft_id      INTEGER      NULL,
  ip_address    TEXT     NOT NULL,
  session_key   TEXT         NULL DEFAULT NULL,
  login_utc     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  logout_utc    DATETIME     NULL DEFAULT NULL,
  heartbeat_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (auth_token_id) REFERENCES auth_tokens (auth_token_id),
  FOREIGN KEY (user_id)       REFERENCES users       (user_id),
  FOREIGN KEY (draft_id)      REFERENCES drafts      (draft_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_idx1 ON sessions (session_key);

CREATE TABLE IF NOT EXISTS migration_user_keys (
  user_id            INTEGER NOT NULL,
  user_key_salt      TEXT    NOT NULL,
  encrypted_priv_key TEXT    NOT NULL,
  priv_key           BLOB        NULL DEFAULT NULL
);
CREATE TABLE IF NOT EXISTS migration_perm_keys (
  user_id     INTEGER NOT NULL,
  project_id  INTEGER NOT NULL,
  key         TEXT    NOT NULL,
  viewed_utc  TEXT    NOT NULL,
  unlock      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS migration_objects (
  project_id  INTEGER NOT NULL,
  object_name TEXT    NOT NULL,
  md5         TEXT    NOT NULL,
  content     BLOB    NOT NULL
);
CREATE INDEX IF NOT EXISTS migration_user_keys_idx1 ON migration_user_keys (user_id);
CREATE INDEX IF NOT EXISTS migration_perm_keys_idx1 ON migration_perm_keys (user_id);
CREATE INDEX IF NOT EXISTS migration_perm_keys_idx2 ON migration_perm_keys (project_id);
CREATE INDEX IF NOT EXISTS migration_objects_idx1   ON migration_objects   (project_id);
CREATE INDEX IF NOT EXISTS migration_objects_idx2   ON migration_objects   (object_name);

INSERT INTO users (user_id, full_name) VALUES (1000, 'atima2');
INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key) VALUES (10000, 'atima2', 0, 0, 0, '');


-- Data -----------------------------------------------------------------------
-- Users: an administrator, a second registered user, and a guest.

INSERT INTO users (user_id, full_name, affiliation, email, is_guest, is_admin) VALUES (1001, 'Ada Lovelace', 'Analytical Engines', 'ada@example.org', 0, 1);
INSERT INTO users (user_id, full_name, affiliation, email, is_guest, is_admin) VALUES (1002, 'Charles Babbage', 'Analytical Engines', 'charles@example.org', 0, 0);
INSERT INTO users (user_id, full_name) VALUES (1003, 'Guest 1003');

INSERT INTO biom_files (biom_file_id, file, hash) VALUES (1, 'aaaaaaaaaa.biom', 'hash-1');
INSERT INTO biom_files (biom_file_id, file, hash) VALUES (2, 'bbbbbbbbbb.biom', 'hash-2');
INSERT INTO biom_files (biom_file_id, file, hash) VALUES (3, 'cccccccccc.biom', 'hash-3');

-- Collections: two public (owned by user 0), one each for Ada and Charles.
INSERT INTO collections (collection_id, user_id, parent_collection_id, jstree_text) VALUES (1, 0,    NULL, 'Examples');
INSERT INTO collections (collection_id, user_id, parent_collection_id, jstree_text) VALUES (2, 1001, NULL, 'My studies');
INSERT INTO collections (collection_id, user_id, parent_collection_id, jstree_text) VALUES (3, 1002, NULL, 'Shared by Ada Lovelace (ada@example.org)');
INSERT INTO collections (collection_id, user_id, parent_collection_id, jstree_text) VALUES (4, 0,    1,    'Human');

-- Projects: public in a public collection; private; public at the top level.
INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, n_views) VALUES (10001, 'HMP50',             1, 2, 3, 'hmp50',        12);
INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, n_views) VALUES (10002, 'Private study',     1, 2, 3, 'Xk3pQ9wLm2Za', 3);
INSERT INTO projects (project_id, title, orig_bf_id, full_bf_id, rare_bf_id, access_key, n_views) VALUES (10003, 'Public, top level', 1, 2, 2, 'toplevel',     0);

INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (1, 0,    10001, 4,    1, NULL);
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (2, 1001, 10002, 2,    1, NULL);
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (3, 1002, 10002, 3,    0, 1001);
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (4, 0,    10003, NULL, 1, NULL);
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (5, 1001, 10003, NULL, 1, NULL);

-- Rows that point at things that no longer exist. 5.0.x never enforced
-- foreign keys, so real databases can contain these.
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (6, 9999, 10002, NULL, 0, NULL);
INSERT INTO permissions (permission_id, user_id, project_id, collection_id, is_editor, grantor_user_id) VALUES (7, 1003, 10001, 99,   0, 9999);

INSERT INTO drafts (draft_id, project_id, full_bf_id, rare_bf_id) VALUES (1, 10001, 2, 3);
INSERT INTO drafts (draft_id, project_id, full_bf_id, rare_bf_id) VALUES (2, 10002, 2, 3);
INSERT INTO drafts (draft_id, project_id, full_bf_id, rare_bf_id) VALUES (3, 55555, 2, 3);

INSERT INTO last_access (user_id, project_id, is_starred, viewed_utc) VALUES (1001, 10002, 1, '2025-03-01 10:00:00');
INSERT INTO last_access (user_id, project_id, is_starred, viewed_utc) VALUES (9999, 10002, 0, '2025-03-02 10:00:00');

INSERT INTO auth_tokens (auth_token_id, auth_token_sha, user_id) VALUES (1, 'sha-of-token-1', 1001);
INSERT INTO auth_tokens (auth_token_id, auth_token_sha, user_id) VALUES (2, 'sha-of-token-2', 1003);

INSERT INTO sessions (session_id, auth_token_id, user_id, draft_id, ip_address, session_key) VALUES (1, 1, 1001, 2, '127.0.0.1', '1abcdefgh');
INSERT INTO sessions (session_id, auth_token_id, user_id, draft_id, ip_address, session_key, logout_utc) VALUES (2, NULL, 1003, 3, '127.0.0.1', '2abcdefgh', '2025-03-03 10:00:00');

-- atima 2 data that nobody claimed.
INSERT INTO migration_user_keys (user_id, user_key_salt, encrypted_priv_key) VALUES (42, 'salt', 'encrypted');
INSERT INTO migration_perm_keys (user_id, project_id, key, viewed_utc) VALUES (42, 7, 'key', '2020-01-01');
INSERT INTO migration_objects (project_id, object_name, md5, content) VALUES (7, 'biom', 'md5', x'00ff');
