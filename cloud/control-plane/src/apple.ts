// Sign in with Apple, on the web (Oby is a Developer ID app, and Apple's native Sign in with
// Apple is App Store only): Apple's identity token, checked against Apple's public keys. Only
// `sub` is kept, the account's stable id for this team; no name or email is asked for.

/// Apple's public keys (https://appleid.apple.com/auth/keys), a JWKS's `keys`.
export interface AppleKeys {
  keys(): Promise<JsonWebKey[]>;
}

export const APPLE_ISSUER = "https://appleid.apple.com";
/// How long a token's `iat` may be in the past, and how far its clock may be ahead of ours.
export const TOKEN_MAX_AGE_SECONDS = 10 * 60;
export const TOKEN_SKEW_SECONDS = 60;
/// The keys are fetched again after this long, or for an unknown `kid` at most this often.
export const KEYS_MAX_AGE_SECONDS = 24 * 60 * 60;
export const KEYS_REFETCH_SECONDS = 60;
export const KEYS_MAX_BACKOFF_SECONDS = 60 * 60;

/// Why a token was refused, in a line for the log; never the token.
export class AppleTokenError extends Error {}

type Jwk = JsonWebKey & { kid?: string };

/// Apple's keys, kept for a day and fetched again for a `kid` not among them (Apple rotates
/// them), at most once a minute so a stream of made-up kids can't make the Worker hammer Apple.
/// A fetch that fails, or answers something that isn't a list of RSA keys, changes nothing: the
/// keys kept stay, and the next try waits twice as long each time (up to an hour) while Apple is
/// down.
export class AppleKeyCache {
  private keys: Jwk[] = [];
  private fetchedAt = Number.NEGATIVE_INFINITY;
  private failedAt = Number.NEGATIVE_INFINITY;
  private failures = 0;

  constructor(
    private readonly source: AppleKeys,
    private readonly now: () => Date,
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
        if (!Array.isArray(keys) || !keys.length || !keys.every(isRSAKey)) throw new AppleTokenError("Apple's keys came back in a shape they never have");
        this.keys = keys;
        this.fetchedAt = seconds;
        this.failures = 0;
      } catch (error) {
        this.failedAt = seconds;
        this.failures++;
        console.warn(`apple keys: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    return this.keys.find((key) => key.kid === kid);
  }
}

function isRSAKey(key: unknown): key is Jwk {
  const jwk = key as Jwk | null;
  return !!jwk && jwk.kty === "RSA" && typeof jwk.kid === "string" && typeof jwk.n === "string" && typeof jwk.e === "string";
}

/// Apple's keys over HTTPS.
export const appleKeysOverHTTPS: AppleKeys = {
  async keys() {
    const response = await fetch("https://appleid.apple.com/auth/keys");
    if (!response.ok) throw new AppleTokenError(`Apple's keys couldn't be read: HTTP ${response.status}`);
    return ((await response.json()) as { keys: JsonWebKey[] }).keys;
  },
};

/// Checks an identity token and returns its `sub`: RS256 signed by one of Apple's keys, issued by
/// Apple for `audience` (the Services ID), not expired, issued within TOKEN_MAX_AGE_SECONDS and
/// not in the future, and carrying the nonce whose SHA-256 (hex) is `nonceHash`: the control
/// plane keeps only the hash of the nonce it handed out. Throws AppleTokenError otherwise.
export async function verifyAppleToken(token: string, cache: AppleKeyCache, audience: string, nonceHash: string, now: Date): Promise<string> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new AppleTokenError("not a JWT");
  const [head, body, signature] = parts as [string, string, string];
  const header = decodeJSON(head) as { alg?: string; kid?: string };
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new AppleTokenError("not RS256 with a kid");
  const jwk = await cache.key(header.kid);
  if (!jwk) throw new AppleTokenError("signed by a key Apple doesn't list");
  const key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, n: jwk.n, e: jwk.e }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signed = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, fromBase64url(signature), new TextEncoder().encode(`${head}.${body}`));
  if (!signed) throw new AppleTokenError("bad signature");
  const claims = decodeJSON(body) as { iss?: string; aud?: string | string[]; exp?: number; iat?: number; nonce?: string; sub?: string };
  if (claims.iss !== APPLE_ISSUER) throw new AppleTokenError("not issued by Apple");
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) throw new AppleTokenError("for another client");
  const seconds = Math.floor(now.getTime() / 1000);
  if (typeof claims.exp !== "number" || claims.exp <= seconds) throw new AppleTokenError("expired");
  if (typeof claims.iat !== "number" || claims.iat > seconds + TOKEN_SKEW_SECONDS || claims.iat < seconds - TOKEN_MAX_AGE_SECONDS) {
    throw new AppleTokenError("issued at the wrong time");
  }
  if (typeof claims.nonce !== "string" || (await sha256Hex(claims.nonce)) !== nonceHash) throw new AppleTokenError("for another sign-in");
  if (typeof claims.sub !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(claims.sub)) throw new AppleTokenError("no account");
  return claims.sub;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function decodeJSON(part: string): unknown {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64url(part)));
  } catch {
    throw new AppleTokenError("unreadable");
  }
}

function fromBase64url(text: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) throw new AppleTokenError("unreadable");
  return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (character) => character.charCodeAt(0));
}
