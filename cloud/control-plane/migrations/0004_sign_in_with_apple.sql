-- Sign in with Apple (the owner's decision of 2026-10-20): a new Mac signs in with Apple on the web
-- before it registers, and each installation belongs to that Apple Account. Only Apple's `sub` is
-- kept: no name, no email.

CREATE TABLE users (
  sub TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

-- A sign-in a Mac started (signed by its key): the `state` Apple sends back, the hash of the
-- nonce Apple puts in the identity token, and, once Apple's token checks out, the account and the
-- hash of the one-time code the browser is sent back with. Used once, to register that key; gone
-- after SIGN_IN_MINUTES (the sweep).
CREATE TABLE sign_ins (
  state TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  nonce_hash TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  sub TEXT REFERENCES users (sub),
  code_hash TEXT,
  used_at TEXT
);
CREATE INDEX sign_ins_by_expiry ON sign_ins (expires_at);

-- No installation was registered before this (the Worker wasn't deployed), so none is left
-- without an account.
ALTER TABLE installations ADD COLUMN user_sub TEXT REFERENCES users (sub);
-- When it first made an endpoint: one that never did is swept after a day, one whose endpoint was
-- reclaimed isn't.
ALTER TABLE installations ADD COLUMN endpoint_at TEXT;
CREATE INDEX installations_by_user ON installations (user_sub);
