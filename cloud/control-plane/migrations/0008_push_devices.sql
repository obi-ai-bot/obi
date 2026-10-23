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

-- How many phones there are, kept by the two triggers, so a registration reads one row rather
-- than counting the table (a count would read every row, and D1's free plan reads 5 M a day).
CREATE TABLE push_device_count (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  n INTEGER NOT NULL
);
INSERT INTO push_device_count (id, n) VALUES (1, 0);
CREATE TRIGGER push_devices_added AFTER INSERT ON push_devices
BEGIN
  UPDATE push_device_count SET n = n + 1 WHERE id = 1;
END;
CREATE TRIGGER push_devices_removed AFTER DELETE ON push_devices
BEGIN
  UPDATE push_device_count SET n = n - 1 WHERE id = 1;
END;

-- The APNs provider token every isolate uses for its 40 minutes (Apple refuses tokens made too
-- often), kept only sealed: AES-256-GCM under a key made from PUSH_SECRET_KEY (src/apns.ts).
CREATE TABLE apns_provider_token (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  made_at INTEGER NOT NULL,
  sealed TEXT NOT NULL
);
