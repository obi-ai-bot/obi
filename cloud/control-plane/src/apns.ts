// Apple's push service for the sealed push relay (#398): the provider token, an ES256 JWT signed
// with the .p8 key in the APNS_* secrets, and one alert sent. APNs speaks HTTP/2 only; a Worker's
// `fetch` does on Cloudflare's edge (#27's spike, 2026-10-23), local workerd doesn't, so the tests
// pass a fake `send`.

import type { Env } from "./env";
import { base64url } from "./tokens";

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

/// How long one provider token is used: Apple wants a new one at most every 20 minutes and at
/// least every 60.
export const TOKEN_MINUTES = 40;

/// The token this isolate made last.
// ponytail: one per isolate, so a few isolates make a few tokens; D1 can't share it (it's a secret).
let cached: { key: APNsKey; token: string; madeAt: number } | null = null;

async function providerToken(key: APNsKey, now: Date): Promise<string> {
  const at = now.getTime();
  const same = cached && cached.key.keyId === key.keyId && cached.key.teamId === key.teamId && cached.key.pem === key.pem;
  if (cached && same && at - cached.madeAt < TOKEN_MINUTES * 60_000) return cached.token;
  const der = Uint8Array.from(atob(key.pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const signer = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const head = `${encode({ alg: "ES256", kid: key.keyId })}.${encode({ iss: key.teamId, iat: Math.floor(at / 1000) })}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(head)));
  cached = { key, token: `${head}.${base64url(signature)}`, madeAt: at };
  return cached.token;
}

export interface Alert {
  token: string;
  topic: string;
  sandbox: boolean;
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

/// Sends one alert. A token Apple says is bad or expired is dropped, so the next push makes another.
export async function sendAlert(send: Send, key: APNsKey, alert: Alert, now: Date): Promise<APNsAnswer> {
  const host = alert.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken(key, now)}`,
    "apns-topic": alert.topic,
    "apns-push-type": "alert",
    "apns-priority": alert.urgent ? "10" : "5",
    "content-type": "application/json",
  };
  if (alert.collapse) headers["apns-collapse-id"] = alert.collapse;
  let answer: Response;
  try {
    answer = await send(`https://${host}/3/device/${alert.token}`, { method: "POST", headers, body: alert.payload, signal: AbortSignal.timeout(10_000) });
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
    if (answer.status === 403) cached = null;
  }
  return { status: answer.status, reason, retryAfter: answer.headers.get("Retry-After") };
}
