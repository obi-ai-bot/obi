-- The sealed push relay (#398, the owner's decision of 2026-10-23): one row per iPhone that
-- registered for pushes, and nothing else. No secret (a phone's pushSecret is made again from its
-- id and the PUSH_SECRET_KEY secret), no Mac, no account, no time, no address: obid's pushes come
-- sealed to the phone's own key and are never kept.
CREATE TABLE push_devices (
  id TEXT PRIMARY KEY,
  apns_token TEXT NOT NULL UNIQUE,
  topic TEXT NOT NULL,
  sandbox INTEGER NOT NULL
);
