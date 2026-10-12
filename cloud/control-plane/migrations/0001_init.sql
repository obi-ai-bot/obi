-- Oby's control plane (#285). Nothing secret is in these tables: tokens and credentials are kept
-- as SHA-256 hashes, and a tunnel's run token is fetched from Cloudflare when the Mac asks for it.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

-- One-time sign-in codes, by email: six digits, ten minutes, five tries.
CREATE TABLE otp_codes (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT
);
CREATE INDEX otp_codes_by_email ON otp_codes (email, created_at);

-- A signed-in device's session: the bearer token `oby_session_…`, hashed.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id),
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

-- One installation per Mac (its stable client id), owned by the user who signed in there.
CREATE TABLE installations (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id),
  client_id TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  -- The session it was registered under: removing the installation signs that device out too.
  session_id TEXT REFERENCES sessions (id),
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT,
  UNIQUE (user_id, client_id)
);

-- An installation's credential `oby_install_…`, hashed; rotating one revokes the last.
CREATE TABLE installation_credentials (
  id TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL REFERENCES installations (id),
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX installation_credentials_by_installation ON installation_credentials (installation_id);

-- The installation's tunnel and hostname (oby-<opaque>.<domain> → <tunnel>.cfargotunnel.com).
CREATE TABLE endpoints (
  installation_id TEXT PRIMARY KEY REFERENCES installations (id),
  tunnel_id TEXT NOT NULL,
  hostname TEXT NOT NULL UNIQUE,
  dns_record_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Fixed windows for the rate limits on sign-in codes, verification attempts and creating installations.
CREATE TABLE rate_limits (
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL
);
