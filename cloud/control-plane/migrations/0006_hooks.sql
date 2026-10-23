-- Webhook addresses (#1128): one row per hook, the address https://<Worker>/h/<id> that a sender
-- (GitHub, Grafana, Alertmanager, PagerDuty, …) posts to and the Worker passes to the Mac's
-- gateway. No body, header, sender address or count of any delivery is ever stored; the hook's
-- secret is only in the Mac's obid.
CREATE TABLE hooks (
  id TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL REFERENCES installations (id),
  created_at TEXT NOT NULL
);
CREATE INDEX hooks_by_installation ON hooks (installation_id);
