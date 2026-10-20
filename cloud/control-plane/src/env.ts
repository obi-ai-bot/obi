/// What the Worker gets from wrangler.jsonc (vars, the D1 binding) and from its secrets.
export interface Env {
  DB: D1Database;
  /// The zone the devices' hostnames are made in: a registrable domain of their own, never the
  /// product's (anyone who runs Oby gets a name under it). Empty until the owner registers one,
  /// and then no endpoint is made.
  DEVICE_DOMAIN: string;
  /// The product's own domain (the Worker's, the Watch API's): DEVICE_DOMAIN may not be it or
  /// under it.
  PRODUCT_DOMAIN: string;
  /// The hostnames' prefix: oby-<opaque>.<DEVICE_DOMAIN>.
  HOSTNAME_PREFIX: string;
  /// How many leading zero bits a new Mac's proof of work needs (src/app.ts, `register`). The Mac
  /// app's `RemoteAccess.workBits` must be at least this.
  REGISTRATION_WORK_BITS: string;
  /// The most endpoints (tunnels and hostnames) alive at once.
  MAX_ENDPOINTS: string;
  /// What every tunnel routes to on the Mac: the gateway, http://127.0.0.1:8810.
  GATEWAY: string;

  // Secrets: `wrangler secret put`, or .dev.vars. Never in D1 and never logged.
  /// A Cloudflare API token with Cloudflare Tunnel: Edit on the account and DNS: Edit on the zone.
  CF_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  CF_ZONE_ID?: string;
}
