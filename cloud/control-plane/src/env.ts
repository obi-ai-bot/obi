/// What the Worker gets from wrangler.jsonc (vars, the D1 binding) and from its secrets.
export interface Env {
  DB: D1Database;
  /// The zone the devices' hostnames are made in: a registrable domain of their own, never the
  /// product's (anyone who signs in gets a name under it), unless MEMBER_WORKSPACES is set. Empty:
  /// no endpoint is made.
  DEVICE_DOMAIN: string;
  /// The product's own domain (the Worker's, the Watch API's): DEVICE_DOMAIN may not be it or
  /// under it, unless MEMBER_WORKSPACES makes this a members-only instance.
  PRODUCT_DOMAIN: string;
  /// The hostnames' prefix: oby-<opaque>.<DEVICE_DOMAIN>.
  HOSTNAME_PREFIX: string;
  /// Sign in with Apple on the web: the Services ID (its `client_id`, and the identity token's
  /// `aud`), and the return URL registered with it, this Worker's /v1/auth/apple/callback.
  APPLE_CLIENT_ID: string;
  APPLE_REDIRECT_URI: string;
  /// Sign in with Google: the OAuth client's id (a Web application client in the instance's own
  /// Google Cloud project; the ID token's `aud`), and its authorized redirect URI, this Worker's
  /// /v1/auth/google/callback. Public: the ID token flow needs no client secret.
  GOOGLE_CLIENT_ID: string;
  GOOGLE_REDIRECT_URI: string;
  /// What every Google account of one Workspace (`hd`, by registrable domain) may have together:
  /// live endpoints, and Macs set up a day (src/app.ts, PER_DOMAIN). Whole numbers.
  WORKSPACE_DOMAIN_ENDPOINTS: string;
  WORKSPACE_DOMAIN_REGISTRATIONS: string;
  /// A members-only instance: Google Workspace domains (`hd`), comma-separated, whose accounts
  /// alone may sign in and register a Mac (Apple, which has no domain, is refused). Empty: anyone
  /// with an Apple or Google account. Only a members-only instance may put the devices' hostnames
  /// under PRODUCT_DOMAIN: then only those accounts get a name there (docs/remote-access.md).
  MEMBER_WORKSPACES?: string;
  /// The most endpoints (tunnels and hostnames) alive at once.
  MAX_ENDPOINTS: string;
  /// What every tunnel routes to on the Mac: the gateway, http://127.0.0.1:8810.
  GATEWAY: string;
  /// The most sealed bytes kept for every Mac together (#1315), in MiB: a whole number.
  QUEUE_TOTAL_MIB: string;
  /// The sealed push relay (#398): the iPhone apps' bundle ids it pushes to, comma-separated
  /// (APNs topics). Empty: no phone registers.
  APNS_TOPICS: string;
  /// The most phones registered for pushes at once: a whole number.
  MAX_PUSH_DEVICES: string;

  // Secrets: `wrangler secret put`, or .dev.vars. Never in D1 and never logged.
  /// A Cloudflare API token with Cloudflare Tunnel: Edit on the account and DNS: Edit on the zone.
  CF_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  CF_ZONE_ID?: string;
  /// The APNs key (an Apple Developer key with Apple Push Notifications service): the .p8 file's
  /// text, its Key ID and the team's ID. Without all three, the relay sends nothing (503).
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /// What every phone's pushSecret is made from, with its pushId (src/app.ts, `pushSecret`), so
  /// no secret is kept: at least 32 random characters. Changing it breaks every registered phone.
  PUSH_SECRET_KEY?: string;
}
