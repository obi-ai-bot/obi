-- Each endpoint's network (the IPv4 /24 or IPv6 /48 of the call that made it), so one network
-- can't hold more than a few unconnected ones; when the sweep last asked Cloudflare whether its
-- tunnel is connected, and when it first saw it connected, so unconnected tunnels are reclaimed
-- (src/app.ts, `sweep`).

ALTER TABLE endpoints ADD COLUMN network TEXT NOT NULL DEFAULT '';
ALTER TABLE endpoints ADD COLUMN checked_at TEXT;
ALTER TABLE endpoints ADD COLUMN connected_at TEXT;
CREATE INDEX endpoints_by_network ON endpoints (network);
CREATE INDEX endpoints_by_checked ON endpoints (checked_at);
