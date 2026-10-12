// Oby's control plane (#285): sign-in by email code, installations (one per Mac, each with its
// own revocable credential) and one Cloudflare Tunnel per installation, behind an opaque hostname.
// `handle` takes the Cloudflare API and the email sender as `deps`, so the tests pass fakes.
//
// Nothing secret is kept: session tokens, installation credentials and sign-in codes are stored
// as SHA-256 hashes, and a tunnel's run token is fetched from Cloudflare when the Mac asks.

import { CloudflareError, CloudflareSetupError, type TunnelAPI } from "./cloudflare";
import { MailSetupError, type Mailer } from "./email";
import type { Env } from "./env";
import { type Limit, takeOne } from "./limits";
import { newId, opaqueLabel, randomToken, sha256, sixDigits, tunnelSecret } from "./tokens";

export interface Deps {
  tunnels: TunnelAPI;
  mail: Mailer;
  /// The clock, for tests of expiry.
  now?: () => Date;
}

/// How long a session lasts, how long a sign-in code lasts, and how many tries one gets.
export const SESSION_DAYS = 90;
export const CODE_MINUTES = 10;
export const CODE_TRIES = 5;
/// Rate limits: codes per email, codes per address, installations per user; and how many
/// installations one account may have.
export const LIMITS = {
  codesPerEmail: { max: 5, windowSeconds: 15 * 60 } satisfies Limit,
  codesPerAddress: { max: 20, windowSeconds: 60 * 60 } satisfies Limit,
  verificationsPerAddress: { max: 20, windowSeconds: 15 * 60 } satisfies Limit,
  installationsPerUser: { max: 10, windowSeconds: 60 * 60 } satisfies Limit,
};
export const MAX_INSTALLATIONS = 20;

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

interface User {
  id: string;
  email: string;
  sessionId: string;
}

interface InstallationRow {
  id: string;
  user_id: string;
  client_id: string;
  name: string;
  platform: string;
  session_id: string | null;
  created_at: string;
  last_seen_at: string | null;
  revoked_at: string | null;
}

interface EndpointRow {
  installation_id: string;
  tunnel_id: string;
  hostname: string;
  dns_record_id: string;
  created_at: string;
}

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now ?? (() => new Date());
  try {
    return await route(request, env, deps, now);
  } catch (error) {
    if (error instanceof Reply) return json({ error: error.message }, error.status, error.headers);
    if (error instanceof CloudflareSetupError || error instanceof MailSetupError) return json({ error: error.message }, 503);
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
  if (path === "/v1/auth/otp/request" && method === "POST") return requestCode(request, env, deps, now);
  if (path === "/v1/auth/otp/verify" && method === "POST") return verifyCode(request, env, now);
  if (path === "/v1/auth/signout" && method === "POST") return signOut(request, env, now);
  if (path === "/v1/me" && method === "GET") return me(request, env, now);
  if (path === "/v1/installations" && method === "GET") return listInstallations(request, env, now);
  if (path === "/v1/installations" && method === "POST") return registerInstallation(request, env, now);
  // The installation's own calls, with its credential; before the `{id}` routes, which `self` would match.
  if (path === "/v1/installations/self" && method === "GET") return showSelf(request, env, now);
  if (path === "/v1/installations/self/endpoint" && method === "POST") return createEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint" && method === "DELETE") return removeEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint/token" && method === "GET") return endpointToken(request, env, deps, now);
  const one = path.match(/^\/v1\/installations\/([^/]+)$/);
  if (one?.[1] && method === "DELETE") return removeInstallation(request, env, deps, now, one[1]);
  const credential = path.match(/^\/v1\/installations\/([^/]+)\/credential$/);
  if (credential?.[1] && method === "POST") return rotateCredential(request, env, now, credential[1]);
  throw new Reply(404, "No such route.");
}

// MARK: Sign-in

async function requestCode(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const body = await readJSON(request);
  const email = emailOf(body.email);
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  await limit(env.DB, `codes:email:${email}`, LIMITS.codesPerEmail, now(), "Too many codes were asked for that email.");
  await limit(env.DB, `codes:address:${address}`, LIMITS.codesPerAddress, now(), "Too many codes were asked for from this network.");
  const at = now();
  const code = sixDigits();
  await env.DB.batch([
    // Only the latest code counts.
    env.DB.prepare("UPDATE otp_codes SET used_at = ?2 WHERE email = ?1 AND used_at IS NULL").bind(email, iso(at)),
    env.DB.prepare("INSERT INTO otp_codes (id, email, code_hash, attempts, created_at, expires_at) VALUES (?1, ?2, ?3, 0, ?4, ?5)").bind(
      newId(),
      email,
      await codeHash(email, code),
      iso(at),
      iso(new Date(at.getTime() + CODE_MINUTES * 60_000)),
    ),
  ]);
  if (env.DEV_ECHO_OTP === "true") return json({ sent: true, devCode: code }, 202, noStore);
  await deps.mail.send(
    email,
    "Your Oby sign-in code",
    `Your Oby sign-in code is ${code}. It works for ${CODE_MINUTES} minutes, once.\n\nIf you didn't ask for it, ignore this email: nobody can sign in without it.`,
  );
  return json({ sent: true }, 202);
}

async function verifyCode(request: Request, env: Env, now: () => Date): Promise<Response> {
  const body = await readJSON(request);
  const email = emailOf(body.email);
  const code = typeof body.code === "string" ? body.code.replace(/\s+/g, "") : "";
  if (!/^\d{6}$/.test(code)) throw new Reply(422, "The code is six digits.");
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  await limit(env.DB, `verifications:address:${address}`, LIMITS.verificationsPerAddress, now(), "Too many sign-in attempts from this network.");
  const row = await env.DB.prepare("SELECT id, code_hash, attempts, expires_at FROM otp_codes WHERE email = ?1 AND used_at IS NULL ORDER BY created_at DESC LIMIT 1")
    .bind(email)
    .first<{ id: string; code_hash: string; attempts: number; expires_at: string }>();
  if (!row || row.expires_at <= iso(now())) throw new Reply(401, "That code has expired. Ask for a new one.");
  const attempt = await env.DB.prepare(
    "UPDATE otp_codes SET attempts = attempts + 1 WHERE id = ?1 AND used_at IS NULL AND attempts < ?2 RETURNING code_hash, expires_at",
  )
    .bind(row.id, CODE_TRIES)
    .first<{ code_hash: string; expires_at: string }>();
  if (!attempt) throw new Reply(401, "Too many tries with that code. Ask for a new one.");
  if (attempt.code_hash !== (await codeHash(email, code))) {
    throw new Reply(401, "That code isn't right.");
  }
  const at = now();
  const claimed = await env.DB.prepare("UPDATE otp_codes SET used_at = ?2 WHERE id = ?1 AND used_at IS NULL RETURNING id")
    .bind(row.id, iso(at))
    .first<{ id: string }>();
  if (!claimed) throw new Reply(401, "That code has expired. Ask for a new one.");
  const user = await upsertUser(env.DB, email, at);
  const token = randomToken("oby_session_");
  const expires = new Date(at.getTime() + SESSION_DAYS * 86_400_000);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)").bind(
      newId(),
      user.id,
      await sha256(token),
      iso(at),
      iso(expires),
    ),
  ]);
  return json({ token, user: { id: user.id, email: user.email }, expiresAt: iso(expires) }, 201, noStore);
}

async function signOut(request: Request, env: Env, now: () => Date): Promise<Response> {
  const user = await sessionUser(request, env, now);
  await env.DB.prepare("UPDATE sessions SET revoked_at = ?2 WHERE id = ?1").bind(user.sessionId, iso(now())).run();
  return new Response(null, { status: 204 });
}

async function me(request: Request, env: Env, now: () => Date): Promise<Response> {
  const user = await sessionUser(request, env, now);
  return json({ user: { id: user.id, email: user.email } });
}

// MARK: Installations

async function listInstallations(request: Request, env: Env, now: () => Date): Promise<Response> {
  const user = await sessionUser(request, env, now);
  const rows = await env.DB.prepare("SELECT * FROM installations WHERE user_id = ?1 AND revoked_at IS NULL ORDER BY created_at").bind(user.id).all<InstallationRow>();
  const installations = [];
  for (const row of rows.results) installations.push(await publicInstallation(env.DB, row));
  return json({ installations });
}

async function registerInstallation(request: Request, env: Env, now: () => Date): Promise<Response> {
  const user = await sessionUser(request, env, now);
  const body = await readJSON(request);
  const clientId = field(body.clientId, "clientId", /^[A-Za-z0-9_-]{8,128}$/, "8 to 128 letters, digits, dashes or underscores");
  const name = field(typeof body.name === "string" ? body.name.trim() : body.name, "name", /^[^\n\r]{1,64}$/, "1 to 64 characters");
  const platform = field(body.platform, "platform", /^[a-z]{2,32}$/, "a lowercase word, like macos");
  await limit(env.DB, `installations:user:${user.id}`, LIMITS.installationsPerUser, now(), "Too many installations were registered lately.");
  const at = now();
  let row = await env.DB.prepare("SELECT * FROM installations WHERE user_id = ?1 AND client_id = ?2").bind(user.id, clientId).first<InstallationRow>();
  let created = false;
  if (row) {
    // The same Mac again (it lost its keychain, or was removed and set up anew): the same
    // installation, under this session, with a fresh credential.
    await env.DB.prepare("UPDATE installations SET name = ?2, platform = ?3, session_id = ?4, last_seen_at = ?5, revoked_at = NULL WHERE id = ?1")
      .bind(row.id, name, platform, user.sessionId, iso(at))
      .run();
    row = { ...row, name, platform, session_id: user.sessionId, last_seen_at: iso(at), revoked_at: null };
  } else {
    const count = await env.DB.prepare("SELECT count(*) AS n FROM installations WHERE user_id = ?1 AND revoked_at IS NULL").bind(user.id).first<{ n: number }>();
    if ((count?.n ?? 0) >= MAX_INSTALLATIONS) throw new Reply(409, `This account has ${MAX_INSTALLATIONS} installations already. Remove one first.`);
    row = { id: newId(), user_id: user.id, client_id: clientId, name, platform, session_id: user.sessionId, created_at: iso(at), last_seen_at: iso(at), revoked_at: null };
    await env.DB.prepare("INSERT INTO installations (id, user_id, client_id, name, platform, session_id, created_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)")
      .bind(row.id, row.user_id, row.client_id, row.name, row.platform, row.session_id, row.created_at, row.last_seen_at)
      .run();
    created = true;
  }
  const credential = await issueCredential(env.DB, row.id, at);
  return json({ installation: await publicInstallation(env.DB, row), credential }, created ? 201 : 200, noStore);
}

async function rotateCredential(request: Request, env: Env, now: () => Date, id: string): Promise<Response> {
  const user = await sessionUser(request, env, now);
  const row = await ownedInstallation(env.DB, user, id);
  const credential = await issueCredential(env.DB, row.id, now());
  return json({ installation: await publicInstallation(env.DB, row), credential }, 200, noStore);
}

async function removeInstallation(request: Request, env: Env, deps: Deps, now: () => Date, id: string): Promise<Response> {
  const user = await sessionUser(request, env, now);
  const row = await ownedInstallation(env.DB, user, id);
  const endpoint = await env.DB.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
  if (endpoint) await tearDown(env.DB, deps.tunnels, endpoint);
  const at = iso(now());
  const statements = [
    env.DB.prepare("UPDATE installation_credentials SET revoked_at = ?2 WHERE installation_id = ?1 AND revoked_at IS NULL").bind(row.id, at),
    env.DB.prepare("UPDATE installations SET revoked_at = ?2 WHERE id = ?1").bind(row.id, at),
  ];
  // The session the Mac registered with goes too, so a lost Mac can't register itself again.
  if (row.session_id) statements.push(env.DB.prepare("UPDATE sessions SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL").bind(row.session_id, at));
  await env.DB.batch(statements);
  return new Response(null, { status: 204 });
}

// MARK: The installation's own calls

async function showSelf(request: Request, env: Env, now: () => Date): Promise<Response> {
  const row = await credentialInstallation(request, env, now);
  return json({ installation: await publicInstallation(env.DB, row) });
}

async function createEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await credentialInstallation(request, env, now);
  const existing = await env.DB.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
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
      const theirs = await env.DB.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
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
  const row = await credentialInstallation(request, env, now);
  const endpoint = await env.DB.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
  if (!endpoint) throw new Reply(404, "This installation has no tunnel yet.");
  const token = await deps.tunnels.tunnelToken(endpoint.tunnel_id);
  return json({ token, hostname: endpoint.hostname }, 200, noStore);
}

async function removeEndpoint(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const row = await credentialInstallation(request, env, now);
  const endpoint = await env.DB.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
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

// MARK: Who's asking

function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(\S+)$/i);
  return match?.[1] ?? null;
}

async function sessionUser(request: Request, env: Env, now: () => Date): Promise<User> {
  const token = bearer(request);
  if (!token?.startsWith("oby_session_")) throw new Reply(401, "Sign in first.");
  const row = await env.DB.prepare(
    "SELECT s.id AS session_id, s.expires_at, u.id, u.email FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?1 AND s.revoked_at IS NULL",
  )
    .bind(await sha256(token))
    .first<{ session_id: string; expires_at: string; id: string; email: string }>();
  if (!row || row.expires_at <= iso(now())) throw new Reply(401, "Sign in again.");
  return { id: row.id, email: row.email, sessionId: row.session_id };
}

async function credentialInstallation(request: Request, env: Env, now: () => Date): Promise<InstallationRow> {
  const token = bearer(request);
  if (!token?.startsWith("oby_install_")) throw new Reply(401, "This needs an installation's credential.");
  const row = await env.DB.prepare(
    "SELECT i.* FROM installation_credentials c JOIN installations i ON i.id = c.installation_id WHERE c.token_hash = ?1 AND c.revoked_at IS NULL AND i.revoked_at IS NULL",
  )
    .bind(await sha256(token))
    .first<InstallationRow>();
  if (!row) throw new Reply(401, "This credential was revoked. Turn remote access on again.");
  await env.DB.prepare("UPDATE installations SET last_seen_at = ?2 WHERE id = ?1").bind(row.id, iso(now())).run();
  return row;
}

/// The user's own installation, or 404: another user's is as good as none.
async function ownedInstallation(db: D1Database, user: User, id: string): Promise<InstallationRow> {
  const row = await db.prepare("SELECT * FROM installations WHERE id = ?1 AND user_id = ?2 AND revoked_at IS NULL").bind(id, user.id).first<InstallationRow>();
  if (!row) throw new Reply(404, "No such installation.");
  return row;
}

/// A new credential for the installation; the ones before are revoked in the same batch.
async function issueCredential(db: D1Database, installation: string, at: Date): Promise<string> {
  const credential = randomToken("oby_install_");
  await db.batch([
    db.prepare("UPDATE installation_credentials SET revoked_at = ?2 WHERE installation_id = ?1 AND revoked_at IS NULL").bind(installation, iso(at)),
    db.prepare("INSERT INTO installation_credentials (id, installation_id, token_hash, created_at) VALUES (?1, ?2, ?3, ?4)").bind(
      newId(),
      installation,
      await sha256(credential),
      iso(at),
    ),
  ]);
  return credential;
}

async function upsertUser(db: D1Database, email: string, at: Date): Promise<{ id: string; email: string }> {
  await db.prepare("INSERT INTO users (id, email, created_at) VALUES (?1, ?2, ?3) ON CONFLICT (email) DO NOTHING").bind(newId(), email, iso(at)).run();
  const user = await db.prepare("SELECT id, email FROM users WHERE email = ?1").bind(email).first<{ id: string; email: string }>();
  if (!user) throw new Error("The user couldn't be saved.");
  return user;
}

// MARK: Shapes and checks

async function publicInstallation(db: D1Database, row: InstallationRow) {
  const endpoint = await db.prepare("SELECT * FROM endpoints WHERE installation_id = ?1").bind(row.id).first<EndpointRow>();
  return {
    id: row.id,
    clientId: row.client_id,
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

function emailOf(value: unknown): string {
  const email = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new Reply(422, "That doesn't look like an email address.");
  return email;
}

function field(value: unknown, name: string, shape: RegExp, said: string): string {
  if (typeof value !== "string" || !shape.test(value)) throw new Reply(422, `${name} is ${said}.`);
  return value;
}

async function codeHash(email: string, code: string): Promise<string> {
  return sha256(`${email}\n${code}`);
}

async function readJSON(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
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
