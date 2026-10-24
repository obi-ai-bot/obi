// Apple's push service for the sealed push relay (#398): the provider token, an ES256 JWT signed
// with the .p8 key in the APNS_* secrets, and one push sent. APNs speaks HTTP/2 only; a Worker's
// `fetch` does on Cloudflare's edge (#27's spike, 2026-10-23), local workerd doesn't, so the tests
// pass a fake `send`.

import type { Env } from "./env";
import { base64url, fromBase64url, randomBytes } from "./tokens";

export type Send = (url: string, init: RequestInit) => Promise<Response>;

export interface APNsKey {
  keyId: string;
  teamId: string;
  /// The .p8 file as Apple gives it: PKCS#8, PEM.
  pem: string;
}

/// The key in the Worker's secrets, or null while any of the three is missing.
export function apnsKey(env: Env): APNsKey | null {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const pem = env.APNS_KEY?.trim();
  return keyId && teamId && pem ? { keyId, teamId, pem } : null;
}

/// What a push needs: how it's sent, the key, and D1 with the secret that seals the provider
/// token kept there.
export interface APNs {
  send: Send;
  key: APNsKey;
  db: D1Database;
  /// PUSH_SECRET_KEY.
  secret: string;
}

/// How long one provider token is used: Apple wants a new one at most every 20 minutes and at
/// least every 60, so every isolate uses the one kept in D1.
export const TOKEN_MINUTES = 40;
/// HMAC's message for the key that seals the provider token in D1.
export const TOKEN_SEAL_INFO = "oby-apns-token/1";

/// The token this isolate used last, as D1 had it.
let cached: { key: APNsKey; token: string; madeAt: number } | null = null;

/// A fresh isolate's view: nothing cached (the tests start one this way).
export function forgetToken(): void {
  cached = null;
}

function sameKey(a: APNsKey, b: APNsKey): boolean {
  return a.keyId === b.keyId && a.teamId === b.teamId && a.pem === b.pem;
}

/// The AES-256-GCM key the provider token is sealed with in D1: the HMAC-SHA-256 of
/// TOKEN_SEAL_INFO under PUSH_SECRET_KEY. The key's id and team are its associated data, so a
/// token made with another key doesn't open.
async function tokenSealKey(secret: string): Promise<CryptoKey> {
  const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const raw = await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(TOKEN_SEAL_INFO));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

/// A provider token as D1 keeps it: base64url of a random 96-bit nonce and the AES-GCM box.
export async function sealToken(secret: string, key: APNsKey, token: string): Promise<string> {
  const nonce = randomBytes(12);
  const additionalData = new TextEncoder().encode(`${key.keyId}\n${key.teamId}`);
  const box = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData }, await tokenSealKey(secret), new TextEncoder().encode(token)));
  const all = new Uint8Array(12 + box.byteLength);
  all.set(nonce);
  all.set(box, 12);
  return base64url(all);
}

async function openToken(secret: string, key: APNsKey, sealed: string): Promise<string | null> {
  const all = fromBase64url(sealed);
  if (!all || all.byteLength < 28) return null;
  try {
    const additionalData = new TextEncoder().encode(`${key.keyId}\n${key.teamId}`);
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.slice(0, 12), additionalData }, await tokenSealKey(secret), all.slice(12));
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}

async function signToken(key: APNsKey, seconds: number): Promise<string> {
  const der = Uint8Array.from(atob(key.pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const signer = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const head = `${encode({ alg: "ES256", kid: key.keyId })}.${encode({ iss: key.teamId, iat: seconds })}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(head)));
  return `${head}.${base64url(signature)}`;
}

/// The provider token every isolate uses: this isolate's while it's fresh, else D1's, else a new
/// one, kept in D1 unless another isolate kept one meanwhile (then that one is used).
async function providerToken(apns: APNs, now: Date): Promise<{ key: APNsKey; token: string; madeAt: number }> {
  const seconds = Math.floor(now.getTime() / 1000);
  const fresh = (madeAt: number) => seconds - madeAt < TOKEN_MINUTES * 60;
  if (cached && sameKey(cached.key, apns.key) && fresh(cached.madeAt)) return cached;
  const read = () => apns.db.prepare("SELECT made_at, sealed FROM apns_provider_token WHERE id = 1").first<{ made_at: number; sealed: string }>();
  const kept = await read();
  if (kept && fresh(kept.made_at)) {
    const token = await openToken(apns.secret, apns.key, kept.sealed);
    if (token) return (cached = { key: apns.key, token, madeAt: kept.made_at });
    // Made with another key or secret: replaced below.
    await apns.db.prepare("DELETE FROM apns_provider_token WHERE made_at = ?1").bind(kept.made_at).run();
  }
  const token = await signToken(apns.key, seconds);
  await apns.db
    .prepare(
      `INSERT INTO apns_provider_token (id, made_at, sealed) VALUES (1, ?1, ?2)
       ON CONFLICT (id) DO UPDATE SET made_at = excluded.made_at, sealed = excluded.sealed WHERE apns_provider_token.made_at <= ?3`,
    )
    .bind(seconds, await sealToken(apns.secret, apns.key, token), seconds - TOKEN_MINUTES * 60)
    .run();
  const won = await read();
  const theirs = won && won.made_at !== seconds ? await openToken(apns.secret, apns.key, won.sealed) : null;
  return (cached = theirs && won ? { key: apns.key, token: theirs, madeAt: won.made_at } : { key: apns.key, token, madeAt: seconds });
}

export interface Push {
  token: string;
  topic: string;
  sandbox: boolean;
  /// An alert, or a background push with nothing to show (how a new token is checked).
  type: "alert" | "background";
  /// The JSON payload, as Apple gets it.
  payload: string;
  urgent: boolean;
  collapse?: string;
}

/// What APNs said: its status, its reason for an error, and `Retry-After` when it gave one. A
/// status of 0 is no answer.
export interface APNsAnswer {
  status: number;
  reason: string | null;
  retryAfter: string | null;
}

/// Sends one push. A provider token Apple refuses is dropped, here and in D1, so the next push
/// makes another.
export async function sendPush(apns: APNs, push: Push, now: Date): Promise<APNsAnswer> {
  const host = push.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const provider = await providerToken(apns, now);
  const headers: Record<string, string> = {
    authorization: `bearer ${provider.token}`,
    "apns-topic": push.topic,
    "apns-push-type": push.type,
    // Apple takes a background push at 5 only.
    "apns-priority": push.urgent && push.type === "alert" ? "10" : "5",
    "content-type": "application/json",
  };
  if (push.collapse) headers["apns-collapse-id"] = push.collapse;
  let answer: Response;
  try {
    answer = await apns.send(`https://${host}/3/device/${push.token}`, { method: "POST", headers, body: push.payload, signal: AbortSignal.timeout(10_000) });
  } catch {
    return { status: 0, reason: null, retryAfter: null };
  }
  let reason: string | null = null;
  if (answer.status !== 200) {
    try {
      const said = (await answer.json()) as { reason?: unknown };
      if (typeof said.reason === "string" && /^[A-Za-z]{1,64}$/.test(said.reason)) reason = said.reason;
    } catch {
      // No reason, then.
    }
    if (answer.status === 403 && reason?.endsWith("ProviderToken")) {
      cached = null;
      await apns.db.prepare("DELETE FROM apns_provider_token WHERE made_at = ?1").bind(provider.madeAt).run();
    }
  }
  return { status: answer.status, reason, retryAfter: answer.headers.get("Retry-After") };
}
