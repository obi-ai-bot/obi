// What the tests call the Worker with: `handle` on the test's own D1, a fake Cloudflare API that
// records its calls, a clock the test moves, and Macs: P-256 keys that sign their calls as the
// Mac app does (Engine/ControlPlane.swift).

import { env } from "cloudflare:test";
import { type Deps, handle, SIGNED_PREFIX } from "../src/app";
import { KeyCache, type KeySource } from "../src/signin";
import { CloudflareError, type Ingress, type TunnelAPI, type TunnelStatus } from "../src/cloudflare";
import type { Env } from "../src/env";

export class FakeTunnels implements TunnelAPI {
  calls: { op: string; args: unknown[] }[] = [];
  tunnels = new Map<string, { name: string; secret: string; ingress?: Ingress[] }>();
  records = new Map<string, { name: string; target: string }>();
  /// Each tunnel's status. One not here never connected, shaped as Cloudflare answers for one:
  /// `conns_inactive_at` set from the start, `conns_active_at` null.
  status = new Map<string, TunnelStatus>();
  static readonly neverConnected: TunnelStatus = { connected: false, activeAt: null, inactiveAt: "2026-10-12T12:00:00.000Z" };
  /// The zone CF_ZONE_ID names.
  zone = "oby-devices.test";
  /// What the next call of that kind answers with, as Cloudflare refusing.
  refuse: Partial<Record<keyof TunnelAPI, string>> = {};
  private count = 0;

  /// Reads of a tunnel's status and the zone, apart from `calls`.
  reads: { op: string; args: unknown[] }[] = [];

  private read(op: keyof TunnelAPI, args: unknown[]): void {
    this.reads.push({ op, args });
    const said = this.refuse[op];
    if (said) throw new CloudflareError(`Couldn't ${op}: ${said}`);
  }

  private check(op: keyof TunnelAPI, args: unknown[]): void {
    this.calls.push({ op, args });
    const said = this.refuse[op];
    if (said) throw new CloudflareError(`Couldn't ${op}: ${said}`);
  }

  async createTunnel(name: string, secret: string): Promise<{ id: string }> {
    this.check("createTunnel", [name, secret]);
    const id = `tunnel-${++this.count}`;
    this.tunnels.set(id, { name, secret });
    return { id };
  }

  async configureTunnel(id: string, ingress: Ingress[]): Promise<void> {
    this.check("configureTunnel", [id, ingress]);
    const tunnel = this.tunnels.get(id);
    if (!tunnel) throw new CloudflareError("Couldn't configure the tunnel: no such tunnel");
    tunnel.ingress = ingress;
  }

  async deleteTunnel(id: string): Promise<void> {
    this.check("deleteTunnel", [id]);
    this.tunnels.delete(id);
  }

  async tunnelToken(id: string): Promise<string> {
    this.check("tunnelToken", [id]);
    if (!this.tunnels.has(id)) throw new CloudflareError("Couldn't read the tunnel's token: no such tunnel");
    return `token-for-${id}`;
  }

  async tunnelStatus(id: string): Promise<TunnelStatus> {
    this.read("tunnelStatus", [id]);
    return this.status.get(id) ?? FakeTunnels.neverConnected;
  }

  async zoneName(): Promise<string> {
    this.read("zoneName", []);
    return this.zone;
  }

  async createCNAME(name: string, target: string): Promise<{ id: string }> {
    this.check("createCNAME", [name, target]);
    const id = `record-${++this.count}`;
    this.records.set(id, { name, target });
    return { id };
  }

  async deleteDNSRecord(id: string): Promise<void> {
    this.check("deleteDNSRecord", [id]);
    this.records.delete(id);
  }

  /// Every tunnel there is now, connected by cloudflared.
  connectAll(at = "2026-10-12T12:00:00.000Z"): void {
    for (const id of this.tunnels.keys()) this.status.set(id, { connected: true, activeAt: at, inactiveAt: null });
  }

  ops(): string[] {
    return this.calls.map((call) => call.op);
  }
}

export interface Answer {
  status: number;
  headers: Headers;
  // biome-ignore lint/suspicious/noExplicitAny: the tests read what they expect.
  body: any;
}

/// A Mac's key pair, made with Web Crypto as the Mac makes it with CryptoKit.
export class Mac {
  private constructor(
    readonly keys: CryptoKeyPair,
    /// The public key as the control plane keeps it: X9.63, base64url.
    readonly publicKey: string,
  ) {}

  static async make(): Promise<Mac> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair;
    const raw = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
    return new Mac(keys, base64url(raw));
  }

  /// The headers that sign `method path` with `body` at `seconds` (Unix time).
  async headers(method: string, path: string, body: string, seconds: number, nonce = crypto.randomUUID()): Promise<Record<string, string>> {
    const message = new TextEncoder().encode(`${SIGNED_PREFIX}\n${method}\n${path}\n${seconds}\n${nonce}\n${body}`);
    const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.keys.privateKey, message));
    return { "Oby-Key": this.publicKey, "Oby-Timestamp": String(seconds), "Oby-Nonce": nonce, "Oby-Signature": base64url(signature) };
  }
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Apple, as far as the control plane sees it: an RSA key that signs identity tokens, listed in
/// a JWKS under `kid`. `fetches` counts how often the Worker asked for the keys.
export class FakeIdP implements KeySource {
  fetches = 0;
  private constructor(
    readonly pair: CryptoKeyPair,
    readonly jwk: JsonWebKey,
    readonly kid: string,
  ) {}

  static async make(kid = "apple-test-1"): Promise<FakeIdP> {
    const pair = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
    return new FakeIdP(pair, jwk, kid);
  }

  async keys(): Promise<JsonWebKey[]> {
    this.fetches++;
    return [{ ...this.jwk, kid: this.kid, alg: "RS256", use: "sig" } as JsonWebKey];
  }

  /// An identity token as Apple signs one, with `claims` over the header's `kid` (or `kid`).
  async token(claims: Record<string, unknown>, kid = this.kid, signer: CryptoKey = this.pair.privateKey): Promise<string> {
    const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const head = `${encode({ alg: "RS256", kid })}.${encode(claims)}`;
    const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signer, new TextEncoder().encode(head)));
    return `${head}.${base64url(signature)}`;
  }
}

/// One fake Apple and one fake Google for every test: making an RSA key is slow.
const sharedApple = await FakeIdP.make();
const sharedGoogle = await FakeIdP.make("google-test-1");

export function testApp(overrides: Partial<Deps> = {}, envOverrides: Partial<Env> = {}, apple: FakeIdP = sharedApple, google: FakeIdP = sharedGoogle) {
  const tunnels = new FakeTunnels();
  let at = new Date("2026-10-12T12:00:00.000Z");
  const time = {
    now: () => at,
    advance(ms: number) {
      at = new Date(at.getTime() + ms);
    },
  };
  const deps: Deps = { tunnels, apple: new KeyCache(apple, () => at), google: new KeyCache(google, () => at, "Google"), now: time.now, ...overrides };
  const settings = { ...env, ...envOverrides };

  /// A request as it reaches the Worker, with `headers` as they are (no signature added).
  async function raw(method: string, path: string, body?: string, headers: Record<string, string> = {}): Promise<Answer> {
    const request = new Request(`https://oby-control.oby.test${path}`, {
      method,
      headers: { ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
      body,
    });
    const response = await handle(request, settings, deps);
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
  }

  /// A call signed by `mac`, now.
  async function call(mac: Mac, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Answer> {
    const text = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
    const signed = await mac.headers(method, path, text ?? "", Math.floor(at.getTime() / 1000));
    return raw(method, path, text, { ...signed, ...headers });
  }

  /// What Apple's token says by default: from Apple, for this client, fresh, with `nonce`.
  const claims = (nonce: string, sub: string) => {
    const seconds = Math.floor(at.getTime() / 1000);
    return { iss: "https://appleid.apple.com", aud: settings.APPLE_CLIENT_ID, exp: seconds + 600, iat: seconds, sub, nonce, c_hash: "x", auth_time: seconds };
  };

  /// What Google's ID token says by default: from Google, for this client, fresh, with `nonce`, a
  /// verified email at `domain`, and `hd` for a Workspace domain.
  const googleClaims = (nonce: string, sub: string, email = "someone@deskree.com", hd: string | null = "deskree.com") => {
    const seconds = Math.floor(at.getTime() / 1000);
    return { iss: "https://accounts.google.com", azp: settings.GOOGLE_CLIENT_ID, aud: settings.GOOGLE_CLIENT_ID, exp: seconds + 3600, iat: seconds, sub, nonce, email, email_verified: true, ...(hd ? { hd } : {}) };
  };

  /// `mac` starts signing in: the state and the nonce from the authorization URL.
  async function startSignIn(mac: Mac, headers: Record<string, string> = {}, provider: "apple" | "google" = "apple") {
    const started = await call(mac, "POST", `/v1/auth/${provider}/start`, undefined, headers);
    if (started.status !== 201) return { started, state: "", nonce: "" };
    const url = new URL(started.body.url);
    return { started, state: url.searchParams.get("state") ?? "", nonce: url.searchParams.get("nonce") ?? "" };
  }

  /// Apple (or Google) posts its form to the callback, as the browser does.
  async function callback(fields: Record<string, string>, headers: Record<string, string> = {}, provider: "apple" | "google" = "apple"): Promise<Answer> {
    return raw("POST", `/v1/auth/${provider}/callback`, new URLSearchParams(fields).toString(), { "Content-Type": "application/x-www-form-urlencoded", ...headers });
  }

  /// Signs `mac` in with Apple as account `sub`, the whole way: start, Apple's token, the
  /// callback. Returns what to register with: the body's `signIn` and `signInCode`.
  async function signIn(mac: Mac, sub = "001234.apple-account.0001", headers: Record<string, string> = {}): Promise<{ signIn: string; signInCode: string }> {
    const { started, state, nonce } = await startSignIn(mac, headers);
    if (started.status !== 201) throw new Error(`starting a sign-in: ${started.status} ${JSON.stringify(started.body)}`);
    const back = await callback({ state, code: "unused", id_token: await apple.token(claims(nonce, sub)) }, headers);
    const location = new URL(back.headers.get("Location") ?? "about:blank");
    if (location.host !== "done" || location.searchParams.get("state") !== state) throw new Error(`the callback said ${location}`);
    return { signIn: state, signInCode: location.searchParams.get("code") ?? "" };
  }

  /// A Google account straight in D1, under `limitDomain` (null: none, as for outlook.com), a
  /// Workspace's or not; returns its key.
  async function googleUser(sub: string, limitDomain: string | null, workspace = false): Promise<string> {
    const key = `google:${sub}`;
    await env.DB.prepare("INSERT INTO users (sub, provider, workspace_domain, email_domain, limit_domain, created_at) VALUES (?1, 'google', ?2, ?3, ?4, ?5)")
      .bind(key, workspace ? limitDomain : null, limitDomain ?? "outlook.com", limitDomain, time.now().toISOString())
      .run();
    return key;
  }

  /// Registers `mac`, signed in with Google as `sub` first (with that email and `hd`), from `ip`.
  async function registerWithGoogle(mac: Mac, sub: string, email: string, hd: string | null, ip = "198.51.100.1"): Promise<Answer> {
    const headers = { "CF-Connecting-IP": ip };
    const { started, state, nonce } = await startSignIn(mac, headers, "google");
    if (started.status !== 201) throw new Error(`starting a sign-in: ${started.status} ${JSON.stringify(started.body)}`);
    const back = await callback({ state, id_token: await google.token(googleClaims(nonce, sub, email, hd)) }, headers, "google");
    const code = new URL(back.headers.get("Location") ?? "about:blank").searchParams.get("code") ?? "";
    return call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state, signInCode: code }, headers);
  }

  /// Registers `mac`, signed in with Apple as `sub` first, and returns the answer: `installation`.
  async function register(mac: Mac, name = "Wellington's MacBook Pro", headers: Record<string, string> = {}, sub = "001234.apple-account.0001"): Promise<Answer> {
    return call(mac, "POST", "/v1/installations", { name, platform: "macos", ...(await signIn(mac, sub, headers)) }, headers);
  }

  /// `count` live endpoints made straight in D1 (no Cloudflare), from `network`, for account
  /// `sub` (none by default).
  async function fill(count: number, network = "fill", sub: string | null = null) {
    if (sub) await env.DB.prepare("INSERT INTO users (sub, created_at) VALUES (?1, ?2) ON CONFLICT DO NOTHING").bind(sub, time.now().toISOString()).run();
    for (let i = 0; i < count; i++) {
      const id = crypto.randomUUID();
      const at = time.now().toISOString();
      await env.DB.batch([
        env.DB.prepare("INSERT INTO installations (id, public_key, user_sub, name, platform, created_at, last_seen_at) VALUES (?1, ?1, ?3, 'Mac', 'macos', ?2, ?2)").bind(id, at, sub),
        env.DB.prepare("INSERT INTO endpoints (installation_id, tunnel_id, hostname, dns_record_id, created_at, network) VALUES (?1, ?1, ?1, ?1, ?2, ?3)").bind(id, at, network),
      ]);
    }
  }

  /// A rate limit's window, counted up to `count` now.
  async function counted(key: string, count: number) {
    await env.DB.prepare("INSERT INTO rate_limits (key, window_start, count) VALUES (?1, ?2, ?3) ON CONFLICT (key) DO UPDATE SET count = ?3")
      .bind(key, Math.floor(at.getTime() / 1000), count)
      .run();
  }

  return { raw, call, register, registerWithGoogle, googleUser, signIn, startSignIn, callback, claims, googleClaims, fill, counted, apple, google, deps, tunnels, time };
}

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
