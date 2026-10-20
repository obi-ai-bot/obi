-- No accounts (2026-10-20): a Mac is known by the P-256 key it made, and signs every call with
-- it. The email sign-in's tables go; no installation was ever registered under them (the Worker
-- wasn't deployed), so nothing is carried over. If a copy of the old Worker did run somewhere and
-- made endpoints, the tunnels (named oby-<installation id>) and their CNAME records stay at
-- Cloudflare after this: remove them by hand in the dashboard (Zero Trust › Networks › Tunnels,
-- and the zone's DNS records) before or after applying it. This migration can't reach them.

DROP TABLE endpoints;
DROP TABLE installation_credentials;
DROP TABLE installations;
DROP TABLE sessions;
DROP TABLE otp_codes;
DROP TABLE users;

-- One installation per key: the Mac's public key, X9.63, base64url. Removed after 30 days with
-- no signed call (the hourly sweep), or by the Mac (Forget This Mac).
CREATE TABLE installations (
  id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE INDEX installations_by_last_seen ON installations (last_seen_at);

-- The installation's tunnel and hostname (oby-<opaque>.<domain> → <tunnel>.cfargotunnel.com).
CREATE TABLE endpoints (
  installation_id TEXT PRIMARY KEY REFERENCES installations (id),
  tunnel_id TEXT NOT NULL,
  hostname TEXT NOT NULL UNIQUE,
  dns_record_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Each signed call's nonce, once per key, until its timestamp is too old to be taken anyway
-- (Unix seconds).
CREATE TABLE nonces (
  public_key TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (public_key, nonce)
);
CREATE INDEX nonces_by_expiry ON nonces (expires_at);
