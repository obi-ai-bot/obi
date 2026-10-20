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
  /// Sign in with Apple on the web: the Services ID (its `client_id`, and the identity token's
  /// `aud`), and the return URL registered with it, this Worker's /v1/auth/apple/callback.
  APPLE_CLIENT_ID: string;
  APPLE_REDIRECT_URI: string;
  /// Sign in with Google: the OAuth client's id (a Web application client in Deskree's Google
  /// Cloud project; the ID token's `aud`), and its authorized redirect URI, this Worker's
  /// /v1/auth/google/callback. Public: the ID token flow needs no client secret.
  GOOGLE_CLIENT_ID: string;
  GOOGLE_REDIRECT_URI: string;
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
