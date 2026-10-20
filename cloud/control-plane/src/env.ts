/// What the Worker gets from wrangler.jsonc (vars, the D1 binding) and from its secrets.
export interface Env {
  DB: D1Database;
  /// The zone the devices' hostnames are made in: tetrix.pro.
  DOMAIN: string;
  /// The hostnames' prefix: oby-<opaque>.<DOMAIN>.
  HOSTNAME_PREFIX: string;
  /// What every tunnel routes to on the Mac: the gateway, http://127.0.0.1:8810.
  GATEWAY: string;

  // Secrets: `wrangler secret put`, or .dev.vars. Never in D1 and never logged.
  /// A Cloudflare API token with Cloudflare Tunnel: Edit on the account and DNS: Edit on the zone.
  CF_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  CF_ZONE_ID?: string;
}
