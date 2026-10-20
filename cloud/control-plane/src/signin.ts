// Signing in on the web, the gate for remote access: Sign in with Apple (Oby is a Developer ID
// app, and Apple's native Sign in with Apple is App Store only) and Sign in with Google. Each
// sends an identity token, an RS256 JWT checked here against that provider's public keys. Apple
// gives only `sub`, the account's stable id for this team, with no name or email asked for.
// Google gives `sub` and the email, asked for only so the account's domains are known (its
// Workspace's, `hd`, and its verified email's); the email itself is never kept.

/// A provider's public keys, a JWKS's `keys`.
export interface KeySource {
  keys(): Promise<JsonWebKey[]>;
}

export const APPLE_ISSUER = "https://appleid.apple.com";
/// Google issues its tokens under either spelling (its OpenID configuration says the https one).
export const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
/// How long a token's `iat` may be in the past, and how far its clock may be ahead of ours.
export const TOKEN_MAX_AGE_SECONDS = 10 * 60;
export const TOKEN_SKEW_SECONDS = 60;
/// The keys are fetched again after this long, or for an unknown `kid` at most this often.
export const KEYS_MAX_AGE_SECONDS = 24 * 60 * 60;
export const KEYS_REFETCH_SECONDS = 60;
export const KEYS_MAX_BACKOFF_SECONDS = 60 * 60;

/// Why a token was refused, in a line for the log; never the token.
export class TokenError extends Error {}

type Jwk = JsonWebKey & { kid?: string };

/// A provider's keys, kept for a day and fetched again for a `kid` not among them (Apple and
/// Google rotate them), at most once a minute so a stream of made-up kids can't make the Worker
/// hammer the provider. A fetch that fails, or answers something that isn't a list of RSA keys,
/// changes nothing: the keys kept stay, and the next try waits twice as long each time (up to an
/// hour) while the provider is down.
export class KeyCache {
  private keys: Jwk[] = [];
  private fetchedAt = Number.NEGATIVE_INFINITY;
  private failedAt = Number.NEGATIVE_INFINITY;
  private failures = 0;

  constructor(
    private readonly source: KeySource,
    private readonly now: () => Date,
    /// Whose keys, for the log.
    private readonly name = "Apple",
  ) {}

  async key(kid: string): Promise<Jwk | undefined> {
    const seconds = this.now().getTime() / 1000;
    const stale = seconds - this.fetchedAt > KEYS_MAX_AGE_SECONDS;
    const unknown = !this.keys.some((key) => key.kid === kid);
    // 1, 2, 4… minutes after the last failure, up to an hour.
    const backingOff = this.failures > 0 && seconds - this.failedAt < Math.min(KEYS_MAX_BACKOFF_SECONDS, KEYS_REFETCH_SECONDS * 2 ** (this.failures - 1));
    if ((stale || (unknown && seconds - this.fetchedAt > KEYS_REFETCH_SECONDS)) && !backingOff) {
      try {
        const keys = await this.source.keys();
        if (!Array.isArray(keys) || !keys.length || !keys.every(isRSAKey)) throw new TokenError(`${this.name}'s keys came back in a shape they never have`);
        this.keys = keys;
        this.fetchedAt = seconds;
        this.failures = 0;
      } catch (error) {
        this.failedAt = seconds;
        this.failures++;
        console.warn(`${this.name.toLowerCase()} keys: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    return this.keys.find((key) => key.kid === kid);
  }
}

function isRSAKey(key: unknown): key is Jwk {
  const jwk = key as Jwk | null;
  return !!jwk && jwk.kty === "RSA" && typeof jwk.kid === "string" && typeof jwk.n === "string" && typeof jwk.e === "string";
}

/// A provider's keys over HTTPS.
function keysOverHTTPS(name: string, url: string): KeySource {
  return {
    async keys() {
      const response = await fetch(url);
      if (!response.ok) throw new TokenError(`${name}'s keys couldn't be read: HTTP ${response.status}`);
      return ((await response.json()) as { keys: JsonWebKey[] }).keys;
    },
  };
}

export const appleKeysOverHTTPS = keysOverHTTPS("Apple", "https://appleid.apple.com/auth/keys");
export const googleKeysOverHTTPS = keysOverHTTPS("Google", "https://www.googleapis.com/oauth2/v3/certs");

/// Checks an identity token and returns its claims: RS256 signed by one of the provider's keys,
/// issued by one of `issuers` for `audience` (the client id), not expired, issued within
/// TOKEN_MAX_AGE_SECONDS and not in the future, carrying the nonce whose SHA-256 (hex) is
/// `nonceHash` (the control plane keeps only the hash of the nonce it handed out), and a `sub`.
/// Throws TokenError otherwise.
async function verifyToken(token: string, cache: KeyCache, issuers: string[], audience: string, nonceHash: string, now: Date): Promise<Record<string, unknown> & { sub: string }> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new TokenError("not a JWT");
  const [head, body, signature] = parts as [string, string, string];
  const header = decodeJSON(head) as { alg?: string; kid?: string };
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new TokenError("not RS256 with a kid");
  const jwk = await cache.key(header.kid);
  if (!jwk) throw new TokenError("signed by a key the provider doesn't list");
  const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, n: jwk.n, e: jwk.e }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signed = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, fromBase64url(signature), new TextEncoder().encode(`${head}.${body}`));
  if (!signed) throw new TokenError("bad signature");
  const claims = decodeJSON(body) as Record<string, unknown> & { iss?: unknown; aud?: unknown; exp?: unknown; iat?: unknown; nonce?: unknown; sub?: unknown };
  if (typeof claims.iss !== "string" || !issuers.includes(claims.iss)) throw new TokenError("not issued by the provider");
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) throw new TokenError("for another client");
  const seconds = Math.floor(now.getTime() / 1000);
  if (typeof claims.exp !== "number" || claims.exp <= seconds) throw new TokenError("expired");
  if (typeof claims.iat !== "number" || claims.iat > seconds + TOKEN_SKEW_SECONDS || claims.iat < seconds - TOKEN_MAX_AGE_SECONDS) {
    throw new TokenError("issued at the wrong time");
  }
  if (typeof claims.nonce !== "string" || (await sha256Hex(claims.nonce)) !== nonceHash) throw new TokenError("for another sign-in");
  if (typeof claims.sub !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(claims.sub)) throw new TokenError("no account");
  return claims as Record<string, unknown> & { sub: string };
}

/// Apple's identity token, for the Services ID `audience`: its `sub`.
export async function verifyAppleToken(token: string, cache: KeyCache, audience: string, nonceHash: string, now: Date): Promise<string> {
  return (await verifyToken(token, cache, [APPLE_ISSUER], audience, nonceHash, now)).sub;
}

/// Google's ID token, for the OAuth client `audience`: its `sub` and two domains that mean
/// different things. `workspaceDomain` is `hd`, set only for an account a Google Workspace manages:
/// the one thing that shows the account belongs to that organization. `emailDomain` is the domain
/// of its email, which Google must have verified; it only shows the address was reachable once (a
/// personal Google account made on alice@deskree.com keeps it after Alice leaves). The email itself
/// isn't returned, so it's never kept.
export async function verifyGoogleToken(
  token: string,
  cache: KeyCache,
  audience: string,
  nonceHash: string,
  now: Date,
): Promise<{ sub: string; workspaceDomain: string | null; emailDomain: string }> {
  const claims = await verifyToken(token, cache, GOOGLE_ISSUERS, audience, nonceHash, now);
  if (claims.email_verified !== true || typeof claims.email !== "string") throw new TokenError("no verified email");
  const emailDomain = domainOf(/^[^@\s]+@([^@\s]+)$/.exec(claims.email)?.[1]);
  if (!emailDomain) throw new TokenError("no email domain");
  const workspaceDomain = claims.hd === undefined ? null : domainOf(claims.hd);
  if (workspaceDomain === undefined) throw new TokenError("an hd that isn't a domain");
  return { sub: claims.sub, workspaceDomain, emailDomain };
}

/// A domain name, lowercased, or undefined when it isn't one.
function domainOf(value: unknown): string | undefined {
  const domain = typeof value === "string" ? value.toLowerCase() : "";
  return /^(?=.{1,253}$)[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(domain) ? domain : undefined;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function decodeJSON(part: string): unknown {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64url(part)));
  } catch {
    throw new TokenError("unreadable");
  }
}

function fromBase64url(text: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) throw new TokenError("unreadable");
  return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (character) => character.charCodeAt(0));
}
