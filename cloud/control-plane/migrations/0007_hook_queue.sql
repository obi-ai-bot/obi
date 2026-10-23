-- Kept deliveries (#1315): while a Mac is away, a hook's delivery is kept sealed to its obid's
-- queue key (a P-256 public key the Mac registers, beside its own), for up to 72 hours. The Worker
-- can't open what it keeps: only the sealed bytes, the hook, the installation, when and how big.
ALTER TABLE installations ADD COLUMN queue_key TEXT;
CREATE TABLE hook_queue (
  id TEXT PRIMARY KEY,
  hook_id TEXT NOT NULL REFERENCES hooks (id),
  installation_id TEXT NOT NULL REFERENCES installations (id),
  received_at TEXT NOT NULL,
  size INTEGER NOT NULL,
  sealed BLOB NOT NULL
);
CREATE INDEX hook_queue_by_installation ON hook_queue (installation_id, received_at);
CREATE INDEX hook_queue_by_hook ON hook_queue (hook_id);
