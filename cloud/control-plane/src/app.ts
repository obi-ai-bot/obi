// Oby's control plane (#285): installations (one per Mac, known by the P-256 key the Mac made)
// and one Cloudflare Tunnel per installation, behind an opaque hostname. There are no accounts and
// no bearer secrets: every call is signed by the Mac's key, with a timestamp and a nonce, so a
// call can't be sent again or changed on the way. `handle` takes the Cloudflare API as `deps`, so
// the tests pass a fake.
//
// Anyone can run Oby, so anyone can get a hostname: the hostnames live on a domain of their own
// (DEVICE_DOMAIN, never the product's), a new Mac pays a proof of work, new Macs and Cloudflare
// calls are rate-limited, live endpoints are capped, and unused or idle installations are swept.
//
// Nothing secret is kept: D1 holds public keys, and a tunnel's run token is fetched from
// Cloudflare when the Mac asks.

import { CloudflareError, CloudflareSetupError, type TunnelAPI, type TunnelStatus } from "./cloudflare";
import type { Env } from "./env";
import { counted, type Limit, takeOne } from "./limits";
import { addressBucket, canonicalKey, leadingZeroBits, networkBucket, newId, opaqueLabel, registrableDomain, tunnelSecret, verifyP256 } from "./tokens";

export interface Deps {
  tunnels: TunnelAPI;
  /// The clock, for tests of expiry.
  now?: () => Date;
}

/// How far a call's timestamp may be from the Worker's clock, either way.
export const SKEW_SECONDS = 5 * 60;
/// An installation no call was signed for in this long is removed, with its tunnel and hostname.
export const IDLE_DAYS = 30;
/// An installation that never made an endpoint is removed after this long.
export const UNUSED_HOURS = 24;
/// An endpoint whose tunnel never connected is reclaimed this long after it was made, and one
/// whose tunnel went down this long ago: a hostname is kept by running cloudflared, not by a
/// signed call now and then.
export const NEVER_CONNECTED_HOURS = 24;
export const DISCONNECTED_HOURS = 72;
/// What one sweep does at Cloudflare, under the Workers free plan's 50 calls a run: up to
/// SWEEP_BATCH idle installations removed (two calls each), and STATUS_BATCH tunnels asked
/// whether they're connected (one call each, two more for each reclaimed). Every 5 minutes, 96
/// of each an hour: more than `endpointsEverywhere` can make, and 500 endpoints checked in about
/// 5 hours.
export const SWEEP_BATCH = 8;
export const STATUS_BATCH = 8;
/// The most live endpoints made from one network (an IPv4 /24 or an IPv6 /48).
export const ENDPOINTS_PER_NETWORK = 3;
/// New installations, per client (an IPv6 /64 is one) and per network (/24 or /48); a key is
/// one installation, and registering the same key again isn't counted. Over everyone, past the
/// breaker the proof of work gets harder instead of anyone being refused. Then each
/// installation's Cloudflare calls, and the same calls over everyone: they share the account's
/// one API token.
export const LIMITS = {
  registrationsPerAddress: { max: 5, windowSeconds: 60 * 60 } satisfies Limit,
  registrationsPerNetwork: { max: 20, windowSeconds: 60 * 60 } satisfies Limit,
  registrationsEverywhere: { max: 1000, windowSeconds: 60 * 60 } satisfies Limit,
  endpointChangesPerInstallation: { max: 5, windowSeconds: 60 * 60 } satisfies Limit,
  tokenReadsPerInstallation: { max: 30, windowSeconds: 60 * 60 } satisfies Limit,
  endpointsEverywhere: { max: 60, windowSeconds: 60 * 60 } satisfies Limit,
  removalsEverywhere: { max: 120, windowSeconds: 60 * 60 } satisfies Limit,
  tokenReadsEverywhere: { max: 300, windowSeconds: 5 * 60 } satisfies Limit,
};
/// How much harder the proof of work gets past half the endpoint cap, past 80% of it, and past
/// the registration breaker; they add up.
export const EXTRA_BITS = { halfFull: 2, nearlyFull: 4, busy: 4 };
/// What a new Mac's proof of work hashes, before its key, its time and its answer, a line each.
export const WORK_PREFIX = "oby-register-v1";
/// What the Mac signs, before the body's bytes: the version, then one field a line.
export const SIGNED_PREFIX = "oby-control-v1";

/// An answer with an error: thrown anywhere, sent as `{"error": …}` with its status.
class Reply extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers: Record<string, string> = {},
    /// More fields in the answer, beside `error`.
    readonly fields: Record<string, unknown> = {},
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
  /// The network the endpoint was made from (`networkBucket`).
  network: string;
  /// When the sweep last asked Cloudflare whether its tunnel is connected.
  checked_at: string | null;
}

/// A call whose signature checked out: the key that signed it, its JSON body, and its nonce,
/// not spent yet (`spend`).
interface Signed {
  key: string;
  body: Record<string, unknown>;
  nonce: string;
  timestamp: number;
}

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now ?? (() => new Date());
  try {
    return await route(request, env, deps, now);
  } catch (error) {
    if (error instanceof Reply) return json({ error: error.message, ...error.fields }, error.status, error.headers);
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
/// installation and its hostname (200). A new key also brings a proof of work: `proof`, a
/// decimal answer such that SHA-256 of WORK_PREFIX, the key, `proofAt` (Unix seconds, within
/// five minutes) and the answer, a line each, starts with REGISTRATION_WORK_BITS zero bits.
async function register(request: Request, env: Env, now: () => Date): Promise<Response> {
  const call = await signed(request, env, now());
  const name = field(typeof call.body.name === "string" ? call.body.name.trim() : call.body.name, "name", /^[^\n\r]{1,64}$/, "1 to 64 characters");
  const platform = field(call.body.platform, "platform", /^[a-z]{2,32}$/, "a lowercase word, like macos");
  const at = iso(now());
  const existing = await byKey(env.DB, call.key);
  if (existing) {
    await spend(env.DB, call);
    await env.DB.prepare("UPDATE installations SET name = ?2, platform = ?3, last_seen_at = ?4 WHERE id = ?1").bind(existing.id, name, platform, at).run();
    return json({ installation: await publicInstallation(env.DB, { ...existing, name, platform, last_seen_at: at }) });
  }
  await checkWork(call, await workBits(env, now()), now());
  await spend(env.DB, call);
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  await limit(env.DB, `registrations:address:${addressBucket(address)}`, LIMITS.registrationsPerAddress, now(), "Too many Macs were set up from this network lately.");
  await limit(env.DB, `registrations:network:${networkBucket(address)}`, LIMITS.registrationsPerNetwork, now(), "Too many Macs were set up from this network lately.");
  // Counted, never refused: past the breaker, `workBits` asks more of the next Mac instead.
  await takeOne(env.DB, "registrations:everywhere", LIMITS.registrationsEverywhere, now());
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
  if (await endpointOf(env.DB, row.id)) await limitRemovals(env.DB, row, now());
  await remove(env.DB, deps.tunnels, row);
  return new Response(null, { status: 204 });
}

// MARK: The installation's tunnel

async function createEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const existing = await endpointOf(env.DB, row.id);
  if (existing) return json({ endpoint: publicEndpoint(existing) });
  const domain = await deviceDomain(env, deps.tunnels);
  // ponytail: the cap is read here and the row written after Cloudflare answers, so calls in
  // flight at once can overshoot it by a few; `endpointsEverywhere` keeps that small. A
  // reservation row would make it exact.
  const cap = whole(env.MAX_ENDPOINTS, "MAX_ENDPOINTS", 1, 100_000);
  const live = (await env.DB.prepare("SELECT count(*) AS n FROM endpoints").first<{ n: number }>())?.n ?? 0;
  if (live >= cap) throw new Reply(503, "Remote access is full right now. Try again later.");
  const network = networkBucket(request.headers.get("CF-Connecting-IP") ?? "unknown");
  const mine = (await env.DB.prepare("SELECT count(*) AS n FROM endpoints WHERE network = ?1").bind(network).first<{ n: number }>())?.n ?? 0;
  if (mine >= ENDPOINTS_PER_NETWORK) throw new Reply(429, `This network has ${ENDPOINTS_PER_NETWORK} Macs with remote access on already.`);
  await limitEndpointChanges(env.DB, row, now());
  await limit(env.DB, "endpoints:everywhere", LIMITS.endpointsEverywhere, now(), "Too many Macs are turning remote access on right now.");
  const hostname = `${env.HOSTNAME_PREFIX}${opaqueLabel()}.${domain}`;
  const tunnel = await deps.tunnels.createTunnel(`oby-${row.id}`, tunnelSecret());
  try {
    // Only the gateway, and nothing else on the Mac, is reachable through the tunnel.
    await deps.tunnels.configureTunnel(tunnel.id, [{ hostname, service: env.GATEWAY }, { service: "http_status:404" }]);
    const record = await deps.tunnels.createCNAME(hostname, `${tunnel.id}.cfargotunnel.com`);
    const endpoint: EndpointRow = { installation_id: row.id, tunnel_id: tunnel.id, hostname, dns_record_id: record.id, created_at: iso(now()), network, checked_at: null };
    try {
      await env.DB.prepare("INSERT INTO endpoints (installation_id, tunnel_id, hostname, dns_record_id, created_at, network) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        .bind(endpoint.installation_id, endpoint.tunnel_id, endpoint.hostname, endpoint.dns_record_id, endpoint.created_at, network)
        .run();
    } catch (error) {
      // Two calls at once: the first one's endpoint stands, this one's tunnel and record go.
      const theirs = await endpointOf(env.DB, row.id);
      await deps.tunnels.deleteDNSRecord(record.id).catch(() => {});
      if (!theirs) throw error;
      await deps.tunnels.deleteTunnel(tunnel.id).catch(() => {});
      return json({ endpoint: publicEndpoint(theirs) });
    }
    // Workers Logs keep it: the owner's alert (docs/remote-access.md) watches for this line.
    if (live + 1 >= cap * 0.8) console.warn(`endpoints: ${live + 1} of ${cap} alive, past 80% of MAX_ENDPOINTS`);
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
  await limit(env.DB, `tokens:installation:${row.id}`, LIMITS.tokenReadsPerInstallation, now(), "This Mac asked for its tunnel's token too often.");
  await limit(env.DB, "tokens:everywhere", LIMITS.tokenReadsEverywhere, now(), "Too many Macs are asking for their tunnels right now.");
  const token = await deps.tunnels.tunnelToken(endpoint.tunnel_id);
  return json({ token, hostname: endpoint.hostname }, 200, noStore);
}

async function removeEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const endpoint = await endpointOf(env.DB, row.id);
  if (endpoint) {
    await limitRemovals(env.DB, row, now());
    await tearDown(env.DB, deps.tunnels, endpoint);
  }
  return new Response(null, { status: 204 });
}

/// Making or removing an installation's endpoint: each is Cloudflare calls on the account's one
/// API token, so one installation can't spend its rate limit for everyone.
async function limitEndpointChanges(db: D1Database, row: InstallationRow, now: Date): Promise<void> {
  await limit(db, `endpoints:installation:${row.id}`, LIMITS.endpointChangesPerInstallation, now, "This Mac changed its tunnel too often.");
}

/// Removing an endpoint: the installation's own limit, and one over everyone.
async function limitRemovals(db: D1Database, row: InstallationRow, now: Date): Promise<void> {
  await limitEndpointChanges(db, row, now);
  await limit(db, "removals:everywhere", LIMITS.removalsEverywhere, now, "Too many Macs are turning remote access off right now.");
}

/// The device domains whose zone was checked against CF_ZONE_ID, in this isolate.
const checkedZones = new Set<string>();

/// DEVICE_DOMAIN, once it's a domain whose registrable domain isn't the product's, and it's the
/// zone CF_ZONE_ID names (asked of Cloudflare once): until then, no endpoint.
async function deviceDomain(env: Env, tunnels: TunnelAPI): Promise<string> {
  const domain = (env.DEVICE_DOMAIN ?? "").trim().toLowerCase();
  const product = (env.PRODUCT_DOMAIN ?? "").trim().toLowerCase();
  const devices = registrableDomain(domain);
  if (!devices) throw new Reply(503, "No device domain is set up: set DEVICE_DOMAIN in wrangler.jsonc to a domain of its own.");
  const products = registrableDomain(product);
  if (!products) throw new Reply(503, "PRODUCT_DOMAIN isn't set in wrangler.jsonc, so DEVICE_DOMAIN can't be checked against it.");
  if (devices === products) throw new Reply(503, "DEVICE_DOMAIN can't share the product's registrable domain: register a domain of its own.");
  if (!checkedZones.has(domain)) {
    const zone = (await tunnels.zoneName()).toLowerCase();
    if (zone !== domain) throw new Reply(503, "CF_ZONE_ID isn't DEVICE_DOMAIN's zone: set it to that zone's id.");
    checkedZones.add(domain);
  }
  return domain;
}

/// A whole number from wrangler.jsonc, or the control plane refuses (fails closed) and says which.
function whole(value: string | undefined, name: string, min: number, max: number): number {
  const number = /^\d{1,9}$/.test((value ?? "").trim()) ? Number(value) : Number.NaN;
  if (!(number >= min && number <= max)) throw new Reply(503, `${name} in wrangler.jsonc isn't a whole number from ${min} to ${max}.`);
  return number;
}

/// The proof of work a new Mac needs now: REGISTRATION_WORK_BITS, more as endpoints near the
/// cap and past the registration breaker.
async function workBits(env: Env, now: Date): Promise<number> {
  let bits = whole(env.REGISTRATION_WORK_BITS, "REGISTRATION_WORK_BITS", 1, 32);
  const cap = whole(env.MAX_ENDPOINTS, "MAX_ENDPOINTS", 1, 100_000);
  const live = (await env.DB.prepare("SELECT count(*) AS n FROM endpoints").first<{ n: number }>())?.n ?? 0;
  if (live >= cap * 0.8) bits += EXTRA_BITS.nearlyFull;
  else if (live >= cap * 0.5) bits += EXTRA_BITS.halfFull;
  if ((await counted(env.DB, "registrations:everywhere", LIMITS.registrationsEverywhere, now)) >= LIMITS.registrationsEverywhere.max) bits += EXTRA_BITS.busy;
  return bits;
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

// MARK: The sweep

/// Cron's job, every 5 minutes (wrangler.jsonc): spent nonces and rate-limit windows a day old
/// go; installations that never made an endpoint go after UNUSED_HOURS, in one statement; up to
/// SWEEP_BATCH installations no Mac has signed a call for in IDLE_DAYS go with their tunnels and
/// hostnames; and the STATUS_BATCH endpoints checked longest ago are asked about at Cloudflare,
/// and reclaimed (`reclaimable`) when their tunnel isn't kept connected. One that Cloudflare
/// refuses is tried again next time.
export async function sweep(env: Env, deps: Deps): Promise<{ removed: number; reclaimed: number; failed: number; unused: number }> {
  const now = (deps.now ?? (() => new Date()))();
  const seconds = Math.floor(now.getTime() / 1000);
  const unusedBefore = iso(new Date(now.getTime() - UNUSED_HOURS * 3_600_000));
  const [, , unused] = await env.DB.batch([
    env.DB.prepare("DELETE FROM nonces WHERE expires_at < ?1").bind(seconds),
    // Every window is an hour or less: a day-old one counts nothing.
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(seconds - 86_400),
    env.DB.prepare("DELETE FROM installations WHERE created_at < ?1 AND NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.installation_id = installations.id)").bind(unusedBefore),
  ]);
  let removed = 0;
  let reclaimed = 0;
  let failed = 0;
  const attempt = async (what: () => Promise<void>) => {
    try {
      await what();
      return true;
    } catch (error) {
      failed++;
      console.error(`sweep: ${error instanceof Error ? error.message : String(error)}`);
      return false;
    }
  };
  const cutoff = iso(new Date(now.getTime() - IDLE_DAYS * 86_400_000));
  const idle = await env.DB.prepare("SELECT * FROM installations WHERE last_seen_at < ?1 ORDER BY last_seen_at LIMIT ?2").bind(cutoff, SWEEP_BATCH).all<InstallationRow>();
  for (const row of idle.results) if (await attempt(() => remove(env.DB, deps.tunnels, row))) removed++;
  // Never-checked first (NULL sorts first), then the longest ago.
  const due = await env.DB.prepare("SELECT * FROM endpoints ORDER BY checked_at LIMIT ?1").bind(STATUS_BATCH).all<EndpointRow>();
  for (const endpoint of due.results) {
    await attempt(async () => {
      const status = await deps.tunnels.tunnelStatus(endpoint.tunnel_id);
      if (reclaimable(endpoint, status, now)) {
        await tearDown(env.DB, deps.tunnels, endpoint);
        reclaimed++;
      } else {
        await env.DB.prepare("UPDATE endpoints SET checked_at = ?2 WHERE installation_id = ?1").bind(endpoint.installation_id, iso(now)).run();
      }
    });
  }
  return { removed, reclaimed, failed, unused: unused?.meta.changes ?? 0 };
}

/// Whether an endpoint's tunnel isn't kept connected: it never came up NEVER_CONNECTED_HOURS
/// after the endpoint was made, or it went down DISCONNECTED_HOURS ago. The installation stays,
/// and a Mac that turns remote access on again gets a new hostname.
export function reclaimable(endpoint: { created_at: string }, status: TunnelStatus, now: Date): boolean {
  if (status.connected) return false;
  const hoursSince = (time: string) => (now.getTime() - Date.parse(time)) / 3_600_000;
  const down = status.inactiveAt ?? status.activeAt;
  if (!down) return hoursSince(endpoint.created_at) >= NEVER_CONNECTED_HOURS;
  return hoursSince(down) >= DISCONNECTED_HOURS;
}

// MARK: Who's asking

/// Checks the call's signature: `Oby-Key` (the Mac's P-256 public key, X9.63, base64url),
/// `Oby-Timestamp` (Unix seconds), `Oby-Nonce` and `Oby-Signature` (ECDSA P-256 with SHA-256,
/// r‖s, base64url) over SIGNED_PREFIX, the method, the path, the timestamp and the nonce, a line
/// each, then the body's bytes. Each nonce works once per key while its timestamp is fresh: the
/// caller spends it (`spend`) once it knows the call is about something that exists, so keys
/// with no installation can't fill the table.
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
  return { key, body: body.length ? parseJSON(body) : {}, nonce, timestamp: Number(timestamp) };
}

/// The call's nonce, used: the same call again is refused.
async function spend(db: D1Database, call: Signed): Promise<void> {
  const fresh = await db.prepare("INSERT INTO nonces (public_key, nonce, expires_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING RETURNING nonce")
    .bind(call.key, call.nonce, call.timestamp + SKEW_SECONDS)
    .first();
  if (!fresh) throw new Reply(401, "That call was made already.");
}

/// The new Mac's proof of work (`register`), at `bits`. Every refusal says how many bits it
/// needs now (`workBits`), so the Mac can work it out again.
async function checkWork(call: Signed, bits: number, now: Date): Promise<void> {
  const refuse = (said: string) => new Reply(403, said, {}, { workBits: bits });
  const at = call.body.proofAt;
  const proof = call.body.proof;
  if (typeof at !== "string" || !/^\d{1,12}$/.test(at) || typeof proof !== "string" || !/^\d{1,20}$/.test(proof)) {
    throw refuse("A new Mac needs a proof of work. Update Oby.");
  }
  if (Math.abs(Number(at) - Math.floor(now.getTime() / 1000)) > SKEW_SECONDS) throw refuse("That proof of work is too old.");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${WORK_PREFIX}\n${call.key}\n${at}\n${proof}`));
  if (leadingZeroBits(new Uint8Array(digest)) < bits) throw refuse("That proof of work doesn't check out.");
}

/// The installation the signing key belongs to; it was seen now.
async function signedInstallation(request: Request, env: Env, now: () => Date): Promise<InstallationRow> {
  const call = await signed(request, env, now());
  const row = await byKey(env.DB, call.key);
  // 410, apart from 401 (a bad signature) and 404 (no such route): the Mac should register again.
  if (!row) throw new Reply(410, "This Mac isn't registered. Turn remote access on again.");
  await spend(env.DB, call);
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
