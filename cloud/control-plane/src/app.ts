// Oby's control plane (#285): installations (one per Mac, known by the P-256 key the Mac made)
// and one Cloudflare Tunnel per installation, behind an opaque hostname. There are no accounts and
// no bearer secrets: every call is signed by the Mac's key, with a timestamp and a nonce, so a
// call can't be sent again or changed on the way. `handle` takes the Cloudflare API as `deps`, so
// the tests pass a fake.
//
// Nothing secret is kept: D1 holds public keys, and a tunnel's run token is fetched from
// Cloudflare when the Mac asks.

import { CloudflareError, CloudflareSetupError, type TunnelAPI } from "./cloudflare";
import type { Env } from "./env";
import { type Limit, takeOne } from "./limits";
import { canonicalKey, newId, opaqueLabel, tunnelSecret, verifyP256 } from "./tokens";

export interface Deps {
  tunnels: TunnelAPI;
  /// The clock, for tests of expiry.
  now?: () => Date;
}

/// How far a call's timestamp may be from the Worker's clock, either way.
export const SKEW_SECONDS = 5 * 60;
/// An installation no call was signed for in this long is removed, with its tunnel and hostname.
export const IDLE_DAYS = 30;
/// How many idle installations one sweep removes: each is two Cloudflare calls.
export const SWEEP_BATCH = 20;
/// New installations, per address and over everyone. A key is one installation, so the key can't
/// make more; registering the same key again isn't counted.
export const LIMITS = {
  registrationsPerAddress: { max: 5, windowSeconds: 60 * 60 } satisfies Limit,
  registrationsEverywhere: { max: 60, windowSeconds: 60 * 60 } satisfies Limit,
};
/// What the Mac signs, before the body's bytes: the version, then one field a line.
export const SIGNED_PREFIX = "oby-control-v1";

/// An answer with an error: thrown anywhere, sent as `{"error": …}` with its status.
class Reply extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

interface InstallationRow {
  id: string;
  public_key: string;
  name: string;
  platform: string;
  created_at: string;
  last_seen_at: string;
}

interface EndpointRow {
  installation_id: string;
  tunnel_id: string;
  hostname: string;
  dns_record_id: string;
  created_at: string;
}

/// A call whose signature checked out: the key that signed it and its JSON body.
interface Signed {
  key: string;
  body: Record<string, unknown>;
}

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now ?? (() => new Date());
  try {
    return await route(request, env, deps, now);
  } catch (error) {
    if (error instanceof Reply) return json({ error: error.message }, error.status, error.headers);
    if (error instanceof CloudflareSetupError) return json({ error: error.message }, 503);
    if (error instanceof CloudflareError) return json({ error: error.message }, 502);
    // Messages never carry a token: the Cloudflare client names its step, not its request.
    console.error(error instanceof Error ? error.message : String(error));
    return json({ error: "Something went wrong on the control plane." }, 500);
  }
}

async function route(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const path = new URL(request.url).pathname.replace(/\/+$/, "") || "/";
  const method = request.method;
  if (path === "/v1/health" && method === "GET") return json({ ok: true });
  if (path === "/v1/installations" && method === "POST") return register(request, env, now);
  if (path === "/v1/installations/self" && method === "GET") return showSelf(request, env, now);
  if (path === "/v1/installations/self" && method === "DELETE") return forget(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint" && method === "POST") return createEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint" && method === "DELETE") return removeEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint/token" && method === "GET") return endpointToken(request, env, deps, now);
  throw new Reply(404, "No such route.");
}

// MARK: Installations

/// Registers the Mac whose key signed the call (201), or, the same key again, keeps its
/// installation and its hostname (200).
async function register(request: Request, env: Env, now: () => Date): Promise<Response> {
  const call = await signed(request, env, now());
  const name = field(typeof call.body.name === "string" ? call.body.name.trim() : call.body.name, "name", /^[^\n\r]{1,64}$/, "1 to 64 characters");
  const platform = field(call.body.platform, "platform", /^[a-z]{2,32}$/, "a lowercase word, like macos");
  const at = iso(now());
  const existing = await byKey(env.DB, call.key);
  if (existing) {
    await env.DB.prepare("UPDATE installations SET name = ?2, platform = ?3, last_seen_at = ?4 WHERE id = ?1").bind(existing.id, name, platform, at).run();
    return json({ installation: await publicInstallation(env.DB, { ...existing, name, platform, last_seen_at: at }) });
  }
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  await limit(env.DB, `registrations:address:${address}`, LIMITS.registrationsPerAddress, now(), "Too many Macs were set up from this network lately.");
  await limit(env.DB, "registrations:everywhere", LIMITS.registrationsEverywhere, now(), "Too many Macs are being set up right now.");
  const row: InstallationRow = { id: newId(), public_key: call.key, name, platform, created_at: at, last_seen_at: at };
  // Two calls at once with one key: the first one's row stands, and both answer with it.
  await env.DB.prepare("INSERT INTO installations (id, public_key, name, platform, created_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (public_key) DO NOTHING")
    .bind(row.id, row.public_key, row.name, row.platform, row.created_at, row.last_seen_at)
    .run();
  const saved = await byKey(env.DB, call.key);
  if (!saved) throw new Error("The installation couldn't be saved.");
  return json({ installation: await publicInstallation(env.DB, saved) }, saved.id === row.id ? 201 : 200);
}

async function showSelf(request: Request, env: Env, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  return json({ installation: await publicInstallation(env.DB, row) });
}

/// Forget This Mac: the tunnel and the record go at Cloudflare, then the installation.
async function forget(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  await remove(env.DB, deps.tunnels, row);
  return new Response(null, { status: 204 });
}

// MARK: The installation's tunnel

async function createEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const existing = await endpointOf(env.DB, row.id);
  if (existing) return json({ endpoint: publicEndpoint(existing) });
  const hostname = `${env.HOSTNAME_PREFIX}${opaqueLabel()}.${env.DOMAIN}`;
  const tunnel = await deps.tunnels.createTunnel(`oby-${row.id}`, tunnelSecret());
  try {
    // Only the gateway, and nothing else on the Mac, is reachable through the tunnel.
    await deps.tunnels.configureTunnel(tunnel.id, [{ hostname, service: env.GATEWAY }, { service: "http_status:404" }]);
    const record = await deps.tunnels.createCNAME(hostname, `${tunnel.id}.cfargotunnel.com`);
    const endpoint: EndpointRow = { installation_id: row.id, tunnel_id: tunnel.id, hostname, dns_record_id: record.id, created_at: iso(now()) };
    try {
      await env.DB.prepare("INSERT INTO endpoints (installation_id, tunnel_id, hostname, dns_record_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
        .bind(endpoint.installation_id, endpoint.tunnel_id, endpoint.hostname, endpoint.dns_record_id, endpoint.created_at)
        .run();
    } catch (error) {
      // Two calls at once: the first one's endpoint stands, this one's tunnel and record go.
      const theirs = await endpointOf(env.DB, row.id);
      await deps.tunnels.deleteDNSRecord(record.id).catch(() => {});
      if (!theirs) throw error;
      await deps.tunnels.deleteTunnel(tunnel.id).catch(() => {});
      return json({ endpoint: publicEndpoint(theirs) });
    }
    return json({ endpoint: publicEndpoint(endpoint) }, 201);
  } catch (error) {
    await deps.tunnels.deleteTunnel(tunnel.id).catch(() => {});
    throw error;
  }
}

async function endpointToken(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const endpoint = await endpointOf(env.DB, row.id);
  if (!endpoint) throw new Reply(404, "This installation has no tunnel yet.");
  const token = await deps.tunnels.tunnelToken(endpoint.tunnel_id);
  return json({ token, hostname: endpoint.hostname }, 200, noStore);
}

async function removeEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const endpoint = await endpointOf(env.DB, row.id);
  if (endpoint) await tearDown(env.DB, deps.tunnels, endpoint);
  return new Response(null, { status: 204 });
}

/// The DNS record and the tunnel go at Cloudflare first, then the row: if Cloudflare refuses,
/// the endpoint stays and the call fails, so nothing is left behind unknown.
async function tearDown(db: D1Database, tunnels: TunnelAPI, endpoint: EndpointRow): Promise<void> {
  await tunnels.deleteDNSRecord(endpoint.dns_record_id);
  await tunnels.deleteTunnel(endpoint.tunnel_id);
  await db.prepare("DELETE FROM endpoints WHERE installation_id = ?1").bind(endpoint.installation_id).run();
}

/// The installation and its endpoint; the endpoint at Cloudflare first, so a refusal keeps both.
async function remove(db: D1Database, tunnels: TunnelAPI, row: InstallationRow): Promise<void> {
  const endpoint = await endpointOf(db, row.id);
  if (endpoint) await tearDown(db, tunnels, endpoint);
  await db.prepare("DELETE FROM installations WHERE id = ?1").bind(row.id).run();
}

// MARK: The hourly sweep

/// Cron's job (wrangler.jsonc): spent nonces go, and so do installations no Mac has signed a
/// call for in IDLE_DAYS, their tunnels and hostnames with them. One Cloudflare refused is tried
/// again next hour.
export async function sweep(env: Env, deps: Deps): Promise<{ removed: number; failed: number }> {
  const now = (deps.now ?? (() => new Date()))();
  await env.DB.prepare("DELETE FROM nonces WHERE expires_at < ?1").bind(Math.floor(now.getTime() / 1000)).run();
  const cutoff = iso(new Date(now.getTime() - IDLE_DAYS * 86_400_000));
  const idle = await env.DB.prepare("SELECT * FROM installations WHERE last_seen_at < ?1 ORDER BY last_seen_at LIMIT ?2").bind(cutoff, SWEEP_BATCH).all<InstallationRow>();
  let removed = 0;
  let failed = 0;
  for (const row of idle.results) {
    try {
      await remove(env.DB, deps.tunnels, row);
      removed++;
    } catch (error) {
      failed++;
      console.error(`sweep: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { removed, failed };
}

// MARK: Who's asking

/// Checks the call's signature: `Oby-Key` (the Mac's P-256 public key, X9.63, base64url),
/// `Oby-Timestamp` (Unix seconds), `Oby-Nonce` and `Oby-Signature` (ECDSA P-256 with SHA-256,
/// r‖s, base64url) over SIGNED_PREFIX, the method, the path, the timestamp and the nonce, a line
/// each, then the body's bytes. Each nonce works once per key while its timestamp is fresh.
async function signed(request: Request, env: Env, now: Date): Promise<Signed> {
  const header = (name: string) => request.headers.get(name) ?? "";
  const key = canonicalKey(header("Oby-Key"));
  const timestamp = header("Oby-Timestamp");
  const nonce = header("Oby-Nonce");
  const signature = header("Oby-Signature");
  if (!key || !signature) throw new Reply(401, "This call needs this Mac's signature.");
  const seconds = Math.floor(now.getTime() / 1000);
  if (!/^\d{1,12}$/.test(timestamp) || Math.abs(Number(timestamp) - seconds) > SKEW_SECONDS) {
    throw new Reply(401, "This Mac's clock is off by more than five minutes.");
  }
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(nonce)) throw new Reply(401, "This call has no nonce.");
  const body = new Uint8Array(await request.arrayBuffer());
  const path = new URL(request.url).pathname;
  const head = new TextEncoder().encode(`${SIGNED_PREFIX}\n${request.method}\n${path}\n${timestamp}\n${nonce}\n`);
  const message = new Uint8Array(head.length + body.length);
  message.set(head);
  message.set(body, head.length);
  if (!(await verifyP256(key, signature, message))) throw new Reply(401, "The signature doesn't match this Mac's key.");
  const fresh = await env.DB.prepare("INSERT INTO nonces (public_key, nonce, expires_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING RETURNING nonce")
    .bind(key, nonce, Number(timestamp) + SKEW_SECONDS)
    .first();
  if (!fresh) throw new Reply(401, "That call was made already.");
  return { key, body: body.length ? parseJSON(body) : {} };
}

/// The installation the signing key belongs to; it was seen now.
async function signedInstallation(request: Request, env: Env, now: () => Date): Promise<InstallationRow> {
  const call = await signed(request, env, now());
  const row = await byKey(env.DB, call.key);
  // 404, not 401: the signature was good, and the Mac should register again.
  if (!row) throw new Reply(404, "This Mac isn't registered. Turn remote access on again.");
  const at = iso(now());
  await env.DB.prepare("UPDATE installations SET last_seen_at = ?2 WHERE id = ?1").bind(row.id, at).run();
  return { ...row, last_seen_at: at };
}

async function byKey(db: D1Database, key: string): Promise<InstallationRow | null> {
  return db.prepare("SELECT * FROM installations WHERE public_key = ?1").bind(key).first<InstallationRow>();
}

async function endpointOf(db: D1Database, installation: string): Promise<EndpointRow | null> {
  return db.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(installation).first<EndpointRow>();
}

// MARK: Shapes and checks

async function publicInstallation(db: D1Database, row: InstallationRow) {
  const endpoint = await endpointOf(db, row.id);
  return {
    id: row.id,
    name: row.name,
    platform: row.platform,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
    endpoint: endpoint ? publicEndpoint(endpoint) : null,
  };
}

function publicEndpoint(row: EndpointRow) {
  return { hostname: row.hostname, tunnelId: row.tunnel_id, createdAt: row.created_at };
}

async function limit(db: D1Database, key: string, limit: Limit, now: Date, said: string): Promise<void> {
  const verdict = await takeOne(db, key, limit, now);
  if (verdict.allowed) return;
  const minutes = Math.ceil(verdict.retryAfterSeconds / 60);
  throw new Reply(429, `${said} Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`, { "Retry-After": String(verdict.retryAfterSeconds) });
}

function field(value: unknown, name: string, shape: RegExp, said: string): string {
  if (typeof value !== "string" || !shape.test(value)) throw new Reply(422, `${name} is ${said}.`);
  return value;
}

function parseJSON(bytes: Uint8Array): Record<string, unknown> {
  try {
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    // Said below.
  }
  throw new Reply(400, "Send a JSON object.");
}

const noStore = { "Cache-Control": "no-store" };

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function iso(date: Date): string {
  return date.toISOString();
}
