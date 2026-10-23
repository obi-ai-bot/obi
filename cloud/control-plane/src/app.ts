// Oby's control plane (#285): installations (one per Mac, known by the P-256 key the Mac made)
// and one Cloudflare Tunnel per installation, behind an opaque hostname. There are no accounts and
// no bearer secrets: every call is signed by the Mac's key, with a timestamp and a nonce, so a
// call can't be sent again or changed on the way. `handle` takes the Cloudflare API as `deps`, so
// the tests pass a fake.
//
// A new Mac signs in first, with Apple or Google on the web (Oby is a Developer ID app), and each
// installation belongs to that account, with a few Macs and endpoints each. The
// hostnames live on a domain of their own (DEVICE_DOMAIN, never the product's); per-network and
// global limits are a backstop; live endpoints are capped; and unused, idle or unconnected
// installations are swept.
//
// Nothing secret is kept: D1 holds public keys, and a tunnel's run token is fetched from
// Cloudflare when the Mac asks. A hook's delivery while its Mac is away is kept only sealed to that
// Mac's obid (#1315), so nothing kept can be read here.
//
// The sealed push relay (#398, the owner's decision of 2026-10-23) is the one part open to any
// phone, members or not: an iPhone registers its APNs token for a pushId and pushSecret, and its
// obid posts alerts sealed to the phone's own key, signed with a key made from that secret. The relay
// sends Apple a fixed alert carrying the sealed blob: it never sees what a push says, and never
// learns which Mac sent it. obid holds only a pushKey made from the secret, so only the phone can
// re-register or forget itself, and APNs' provider token is kept in D1 only sealed (src/apns.ts).

import { type APNs, type APNsAnswer, apnsKey, type Send, sendPush } from "./apns";
import { CloudflareError, CloudflareSetupError, type TunnelAPI, type TunnelStatus } from "./cloudflare";
import type { Env } from "./env";
import { counted as countedSoFar, type Limit, takeOne } from "./limits";
import { type KeyCache, sha256Hex, TokenError, verifyAppleToken, verifyGoogleToken } from "./signin";
import { addressBucket, base64, canonicalKey, fromBase64url, networkBucket, newId, opaqueLabel, randomBytes, registrableDomain, tunnelSecret, verifyP256 } from "./tokens";

export interface Deps {
  tunnels: TunnelAPI;
  /// How a hook's delivery goes on to the Mac (`fetch`); a test's stand-in sees what would be sent.
  forward?: (url: string, init: RequestInit) => Promise<Response>;
  /// How a push goes to Apple (`fetch`, HTTP/2 on Cloudflare's edge); a test's stand-in plays APNs.
  apns?: Send;
  /// Apple's and Google's public keys, for their identity tokens.
  apple: KeyCache;
  google: KeyCache;
  /// The clock, for tests of expiry.
  now?: () => Date;
}

/// How far a call's timestamp may be from the Worker's clock, either way.
export const SKEW_SECONDS = 5 * 60;
/// An installation no call was signed for in this long is removed, with its tunnel and hostname.
export const IDLE_DAYS = 30;
/// An installation that never made an endpoint is removed after this long.
export const UNUSED_HOURS = 24;
/// An endpoint whose tunnel never connected is reclaimed this long after it was made (a real Mac
/// connects within seconds), and one whose tunnel went down this long ago; the installation is
/// kept either way, so a Mac behind a firewall that stops cloudflared keeps its sign-in. A hostname is kept by running cloudflared, not by a signed
/// call now and then.
export const NEVER_CONNECTED_HOURS = 1;
export const DISCONNECTED_HOURS = 72;
/// What one sweep does at Cloudflare, under the Workers free plan's 50 calls a run: up to
/// SWEEP_BATCH idle installations removed (two calls each), and STATUS_BATCH tunnels asked
/// whether they're connected (one call each, two more for each reclaimed): at most 40. Every
/// minute, 480 of each an hour: more than `endpointsEverywhere` can make, and 500 endpoints
/// checked about once an hour.
export const SWEEP_BATCH = 8;
export const STATUS_BATCH = 8;
/// The most endpoints from one network (an IPv4 /24 or an IPv6 /48) whose tunnel hasn't
/// connected yet: a generous backstop. Connected ones don't count, so offices, carrier-grade NAT
/// and mobile networks can have many.
export const UNCONNECTED_PER_NETWORK = 20;
/// What one account (Apple or Google) may have: live installations and live endpoints.
export const PER_ACCOUNT = { installations: 5, endpoints: 5 };
/// What every Google account under one registrable domain (`users.limit_domain`) may have
/// together: live endpoints, and Macs set up a day. Google accounts are cheap in bulk (a domain on
/// free Cloud Identity, or a catch-all domain, gives hundreds, and subdomains as many as you like),
/// so per-account limits alone wouldn't keep one domain from filling MAX_ENDPOINTS. A Workspace
/// account (`hd`) is counted under its Workspace's domain, with the allowance in wrangler.jsonc
/// (WORKSPACE_DOMAIN_*); any other under its email's, with the fixed one here. Public mail
/// providers say nothing about who owns an account, and one shared bucket would let a stranger
/// lock their users out, so their accounts aren't limited together; Apple accounts have no domain.
export const PER_DOMAIN = { endpoints: 25, registrations: 20 };
/// Free mail providers whose addresses a Google account may use: exact registrable domains, never
/// a pattern, so a look-alike (`yahoo.xyz`) isn't exempt. Small ones not here share a bucket per
/// domain: a residual risk of lock-out for their users, not of abuse.
export const PUBLIC_MAIL_DOMAINS = new Set([
  "gmail.com", "googlemail.com",
  "outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk", "outlook.fr", "hotmail.fr", "live.co.uk",
  "yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.co.jp", "yahoo.fr", "yahoo.de", "yahoo.it", "yahoo.es", "yahoo.ca", "yahoo.co.in", "yahoo.com.br", "yahoo.com.au", "yahoo.com.mx", "yahoo.com.ar",
  "icloud.com", "me.com", "mac.com",
  "proton.me", "protonmail.com", "pm.me",
  "aol.com",
  "gmx.com", "gmx.net", "gmx.de", "gmx.at", "gmx.ch", "web.de",
  "yandex.ru", "yandex.com", "ya.ru",
  "mail.ru", "qq.com", "163.com", "126.com",
]);
/// How long a sign-in started on a Mac has to finish at Apple or Google and be used to register.
export const SIGN_IN_MINUTES = 10;
/// Sign-ins started, and new installations, per account (`users.sub`) and, as a generous backstop,
/// per client (an IPv6 /64 is one) and per network (/24 or /48); a key is one installation, and
/// registering the same key again isn't counted. Then endpoint creations per account,
/// installation and network, and each installation's Cloudflare calls, and the same calls over
/// everyone: they share the account's one API token.
export const LIMITS = {
  signInsPerAddress: { max: 30, windowSeconds: 60 * 60 } satisfies Limit,
  signInCallbacksPerAddress: { max: 60, windowSeconds: 60 * 60 } satisfies Limit,
  registrationsPerAccount: { max: 10, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  registrationsPerAddress: { max: 20, windowSeconds: 60 * 60 } satisfies Limit,
  registrationsPerNetwork: { max: 100, windowSeconds: 60 * 60 } satisfies Limit,
  endpointChangesPerInstallation: { max: 5, windowSeconds: 60 * 60 } satisfies Limit,
  creationsPerInstallation: { max: 3, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  creationsPerAccount: { max: 10, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  creationsPerNetworkHour: { max: 30, windowSeconds: 60 * 60 } satisfies Limit,
  creationsPerNetworkDay: { max: 100, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  tokenReadsPerInstallation: { max: 4, windowSeconds: 60 * 60 } satisfies Limit,
  endpointsEverywhere: { max: 300, windowSeconds: 60 * 60 } satisfies Limit,
  removalsEverywhere: { max: 120, windowSeconds: 60 * 60 } satisfies Limit,
  tokenReadsEverywhere: { max: 300, windowSeconds: 5 * 60 } satisfies Limit,
  hooksMadePerInstallation: { max: 20, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  deliveriesPerHookMinute: { max: 60, windowSeconds: 60 } satisfies Limit,
  deliveriesPerHookDay: { max: 2000, windowSeconds: 24 * 60 * 60 } satisfies Limit,
  // The push relay (#398): new phones per client, network and everyone; a phone registering its
  // token again; a token checked with Apple; and pushes per phone (by pushId and by token),
  // counted only once their MAC checks out. Their windows are whole minutes, hours or days.
  phonesPerAddress: { max: 30, windowSeconds: 60 * 60 } satisfies Limit,
  phonesPerNetwork: { max: 200, windowSeconds: 60 * 60 } satisfies Limit,
  phonesEverywhere: { max: 2000, windowSeconds: 60 * 60 } satisfies Limit,
  reRegistrationsPerPhone: { max: 20, windowSeconds: 60 * 60 } satisfies Limit,
  tokenChecksPerToken: { max: 10, windowSeconds: 60 * 60 } satisfies Limit,
  pushesPerPhoneMinute: { max: 30, windowSeconds: 60 } satisfies Limit,
  pushesPerPhoneDay: { max: 1000, windowSeconds: 24 * 60 * 60 } satisfies Limit,
};
/// The most hooks one installation has at once.
export const HOOKS_PER_INSTALLATION = 20;
/// The biggest delivery passed on; a bigger one is refused, read only this far.
export const HOOK_BODY_MAX = 1024 * 1024;
/// How long a delivery waits for the Mac.
export const HOOK_WAIT_MS = 10_000;
/// The only headers a delivery carries on to the Mac: the content's type and the senders' own
/// signatures and ids (GitHub's; Oby's generic one; Grafana's, Alertmanager's token header,
/// PagerDuty's for #1311 and #1312). Never a cookie, `Authorization` or one of Cloudflare's.
export const HOOK_HEADERS = [
  "Content-Type",
  "X-Hub-Signature-256",
  "X-GitHub-Event",
  "X-GitHub-Delivery",
  "X-Oby-Signature-256",
  "X-Oby-Token",
  "X-Grafana-Alerting-Signature",
  "X-Grafana-Alerting-Timestamp",
  "X-PagerDuty-Signature",
];
/// What the Mac signs, before the body's bytes: the version, then one field a line.
export const SIGNED_PREFIX = "oby-control-v1";
/// Kept deliveries (#1315): the biggest body kept, how many and how many sealed bytes one
/// installation may have kept, how long, and how many one call hands over. Past a bound the answer
/// is 503, as when nothing is kept.
export const QUEUE = { bodyMax: 256 * 1024, perInstallation: 100, bytesPerInstallation: 2 * 1024 * 1024, hours: 72, batch: 20 };
/// HKDF's `info` when a delivery is sealed; obid opens with the same.
export const QUEUE_INFO = "oby-hook-queue/1";
/// The push relay (#398): the biggest registration and push bodies, and the most base64url
/// characters `sealed` may have, so Apple's payload stays under its 4 KB.
export const PUSH = { registrationMax: 1024, bodyMax: 4096, sealedMax: 3072 };
/// What every push shows until the phone's Notification Service Extension opens what's sealed.
export const PUSH_ALERT = { title: "Oby", body: "Open Oby to see it." };
/// What a pushSecret is the HMAC of, with the pushId (`pushSecret`), and a pushKey (`pushKey`).
export const PUSH_SECRET_INFO = "oby-push-secret/1";
export const PUSH_KEY_INFO = "oby push key v1";
/// How far a push's `at` may be from the relay's clock, either way.
export const PUSH_SKEW_SECONDS = 5 * 60;
/// A pushId: 24 base64url characters when made here (18 random bytes, 144 bits).
const PUSH_ID = /^[A-Za-z0-9_-]{22,64}$/;

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
  /// The account it belongs to (`users.sub`).
  user_sub: string | null;
  /// When it first made an endpoint.
  endpoint_at?: string | null;
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
  /// When the sweep first saw its tunnel connected; null until then.
  connected_at: string | null;
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
  if (path === "/v1/auth" && method === "GET") return json(signInOptions(env));
  for (const provider of ["apple", "google"] as const) {
    if (path === `/v1/auth/${provider}/start` && method === "POST") return startSignIn(request, env, now, provider);
    if (path === `/v1/auth/${provider}/callback` && method === "POST") return finishSignIn(request, env, deps, now, provider);
  }
  if (path === "/v1/installations" && method === "POST") return register(request, env, deps, now);
  if (path === "/v1/installations/self" && method === "GET") return showSelf(request, env, now);
  if (path === "/v1/installations/self" && method === "DELETE") return forget(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint" && method === "POST") return createEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint" && method === "DELETE") return removeEndpoint(request, env, deps, now);
  if (path === "/v1/installations/self/endpoint/token" && method === "GET") return endpointToken(request, env, deps, now);
  if (path === "/v1/installations/self/hooks" && method === "POST") return createHook(request, env, now);
  if (path === "/v1/installations/self/hooks" && method === "GET") return listHooks(request, env, now);
  if (path === "/v1/installations/self/queue-key" && method === "PUT") return setQueueKey(request, env, now);
  if (path === "/v1/installations/self/hooks/queue" && method === "GET") return keptItems(request, env, now);
  const kept = /^\/v1\/installations\/self\/hooks\/queue\/([a-z0-9]{32})$/.exec(path);
  if (kept?.[1] && method === "DELETE") return removeKept(request, env, now, kept[1]);
  const hook = /^\/v1\/installations\/self\/hooks\/([a-z0-9]{32})$/.exec(path);
  if (hook?.[1] && method === "DELETE") return removeHook(request, env, now, hook[1]);
  if (path === "/v1/push/devices" && method === "POST") return registerPhone(request, env, deps, now);
  const phone = /^\/v1\/push\/devices\/([A-Za-z0-9_-]{22,64})$/.exec(path);
  if (phone?.[1] && method === "DELETE") return forgetPhone(request, env, phone[1]);
  if (path === "/v1/push" && method === "POST") return push(request, env, deps, now);
  const delivery = /^\/h\/([^/]+)$/.exec(path);
  if (delivery?.[1]) {
    if (method !== "POST") throw new Reply(405, "A hook takes POST only.", { Allow: "POST" });
    return deliver(request, env, deps, now, delivery[1]);
  }
  throw new Reply(404, "No such route.");
}

// MARK: Signing in: Apple and Google

/// Who an account signs in with, and what its sign-in needs: the authorization page, what's asked
/// of it, the wrangler.jsonc settings, and how its token is checked. An account is (provider, the
/// provider's `sub`), kept as one key (`account`): Apple's `sub` as it is, `google:<sub>` for Google.
type Provider = "apple" | "google";
const PROVIDERS: Record<Provider, { name: string; client: keyof Env; redirect: keyof Env; authorize: string; ask: Record<string, string> }> = {
  // No scope: Apple sends no name and no email.
  apple: { name: "Apple", client: "APPLE_CLIENT_ID", redirect: "APPLE_REDIRECT_URI", authorize: "https://appleid.apple.com/auth/authorize", ask: { response_type: "code id_token" } },
  // The ID token alone (no code, so no client secret), and the email only so its domain is known.
  google: {
    name: "Google",
    client: "GOOGLE_CLIENT_ID",
    redirect: "GOOGLE_REDIRECT_URI",
    authorize: "https://accounts.google.com/o/oauth2/v2/auth",
    ask: { response_type: "id_token", scope: "openid email", prompt: "select_account" },
  },
};

/// A Mac starts signing in, signed by its key: a single-use sign-in (`state`, and a nonce whose
/// hash only is kept) bound to that key and the provider, and the provider's authorization URL
/// for it, answered with a form post to the callback.
async function startSignIn(request: Request, env: Env, now: () => Date, provider: Provider): Promise<Response> {
  const call = await signed(request, env, now());
  const members = memberWorkspaces(env);
  if (members.length && provider === "apple") throw new Reply(403, `This Oby is for ${members.join(", ")} accounts only: sign in with Google.`);
  const client = setting(env, provider, "client");
  const redirect = setting(env, provider, "redirect");
  const address = addressBucket(request.headers.get("CF-Connecting-IP") ?? "unknown");
  await limit(env.DB, `sign-ins:address:${address}`, LIMITS.signInsPerAddress, now(), "Too many sign-ins were started from this network lately.");
  await spend(env.DB, call);
  const state = base64url(randomBytes(32));
  const nonce = base64url(randomBytes(32));
  const at = now();
  await env.DB.prepare("INSERT INTO sign_ins (state, public_key, nonce_hash, created_at, expires_at, provider) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    .bind(state, call.key, await sha256Hex(nonce), iso(at), Math.floor(at.getTime() / 1000) + SIGN_IN_MINUTES * 60, provider)
    .run();
  const url = new URL(PROVIDERS[provider].authorize);
  url.search = new URLSearchParams({ client_id: client, redirect_uri: redirect, ...PROVIDERS[provider].ask, response_mode: "form_post", state, nonce }).toString();
  return json({ url: url.toString(), state }, 201, noStore);
}

/// The provider posts the sign-in's result here (form_post): the identity token is checked against
/// the sign-in it names (`state`), started for this provider, and the account is bound to it with
/// a one-time `code`, kept only as its hash. The browser is sent back to the Mac
/// (`oby-signin://done?state=…&code=…`), which registers with both. The code goes only to the
/// browser that signed in: someone who started the sign-in on their own Mac and got another person
/// to finish it at the provider has the state, not the code, so the other person's account can't
/// be bound to their Mac.
async function finishSignIn(request: Request, env: Env, deps: Deps, now: () => Date, provider: Provider): Promise<Response> {
  const back = (outcome: "done" | "failed", state: string, code?: string) =>
    new Response(null, {
      status: 303,
      headers: { Location: `oby-signin://${outcome}?state=${encodeURIComponent(state)}${code ? `&code=${code}` : ""}`, ...noStore },
    });
  const address = addressBucket(request.headers.get("CF-Connecting-IP") ?? "unknown");
  await limit(env.DB, `sign-in-callbacks:address:${address}`, LIMITS.signInCallbacksPerAddress, now(), "Too many sign-ins from this network lately.");
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    throw new Reply(400, `Send ${PROVIDERS[provider].name}'s form.`);
  }
  const state = String(form.get("state") ?? "");
  const token = String(form.get("id_token") ?? "");
  if (!/^[A-Za-z0-9_-]{43}$/.test(state)) throw new Reply(400, "That sign-in isn't Oby's.");
  const seconds = Math.floor(now().getTime() / 1000);
  const pending = await env.DB.prepare("SELECT nonce_hash FROM sign_ins WHERE state = ?1 AND provider = ?2 AND sub IS NULL AND used_at IS NULL AND expires_at > ?3")
    .bind(state, provider, seconds)
    .first<{ nonce_hash: string }>();
  // Cancelled at the provider (`error`), or no such sign-in, or used already: back to the Mac, which says so.
  if (!pending || !token) return back("failed", state);
  let account: string;
  let domains: { workspace: string | null; email: string | null; limit: string | null } = { workspace: null, email: null, limit: null };
  try {
    const audience = setting(env, provider, "client");
    if (provider === "google") {
      const google = await verifyGoogleToken(token, deps.google, audience, pending.nonce_hash, now());
      if (!isMember(env, google.workspaceDomain)) throw new TokenError(`not a member Workspace: ${google.workspaceDomain ?? "a personal account"}`);
      account = `google:${google.sub}`;
      domains = { workspace: google.workspaceDomain, email: google.emailDomain, limit: limitDomain(google.workspaceDomain, google.emailDomain) };
    } else {
      if (memberWorkspaces(env).length) throw new TokenError("Apple accounts have no Workspace: this instance is members-only");
      account = await verifyAppleToken(token, deps.apple, audience, pending.nonce_hash, now());
    }
  } catch (error) {
    if (!(error instanceof TokenError)) throw error;
    console.warn(`sign in with ${provider}: ${error.message}`);
    return back("failed", state);
  }
  const code = base64url(randomBytes(32));
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO users (sub, provider, workspace_domain, email_domain, limit_domain, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT (sub) DO UPDATE SET workspace_domain = excluded.workspace_domain, email_domain = excluded.email_domain, limit_domain = excluded.limit_domain`,
    ).bind(account, provider, domains.workspace, domains.email, domains.limit, iso(now())),
    env.DB.prepare("UPDATE sign_ins SET sub = ?2, code_hash = ?3 WHERE state = ?1 AND sub IS NULL").bind(state, account, await sha256Hex(code)),
  ]);
  return back("done", state, code);
}

/// MEMBER_WORKSPACES, lowercased: the Google Workspaces a members-only instance serves; none for an
/// open one.
function memberWorkspaces(env: Env): string[] {
  return (env.MEMBER_WORKSPACES ?? "").split(",").map((d) => d.trim().toLowerCase()).filter(Boolean);
}

/// Whether an account of Workspace `workspace` (Google's `hd`; null for a personal account) may
/// use this instance: any account on an open one, only a member Workspace's on a members-only one.
function isMember(env: Env, workspace: string | null): boolean {
  const members = memberWorkspaces(env);
  return !members.length || (!!workspace && members.includes(workspace.toLowerCase()));
}

/// The registrable domain a Google account's limits are shared under (`users.limit_domain`): its
/// Workspace's, so `a.evil.com` and `b.evil.com` are one; else its email's, unless that's a public
/// mail provider (null). A domain the short suffix list can't reduce is kept whole: never no limit.
function limitDomain(workspace: string | null, email: string): string | null {
  if (workspace) return registrableDomain(workspace) ?? workspace;
  const domain = registrableDomain(email) ?? email;
  return PUBLIC_MAIL_DOMAINS.has(domain) ? null : domain;
}

/// What an account's domain may have together (PER_DOMAIN): a Workspace's allowance from
/// wrangler.jsonc, or the fixed one for an email domain.
function domainAllowance(env: Env, workspace: boolean): { endpoints: number; registrations: number } {
  if (!workspace) return PER_DOMAIN;
  return {
    endpoints: whole(env.WORKSPACE_DOMAIN_ENDPOINTS, "WORKSPACE_DOMAIN_ENDPOINTS", 1, 100_000),
    registrations: whole(env.WORKSPACE_DOMAIN_REGISTRATIONS, "WORKSPACE_DOMAIN_REGISTRATIONS", 1, 100_000),
  };
}

/// A provider's setting from wrangler.jsonc, or the control plane says it isn't set up.
/// What a Mac shows before it signs in (`GET /v1/auth`): the providers this instance takes, set up
/// and allowed (a members-only instance refuses Apple), and the Workspaces it's for, if it's
/// members-only. Nothing secret: the same as the refusals say.
function signInOptions(env: Env): { providers: Provider[]; workspaces: string[] } {
  const workspaces = memberWorkspaces(env);
  const providers = (Object.keys(PROVIDERS) as Provider[]).filter(
    (p) => String(env[PROVIDERS[p].client] ?? "").trim() && !(p === "apple" && workspaces.length),
  );
  return { providers, workspaces };
}

function setting(env: Env, provider: Provider, which: "client" | "redirect"): string {
  const name = PROVIDERS[provider][which];
  const text = String(env[name] ?? "").trim();
  if (!text) throw new Reply(503, `Sign in with ${PROVIDERS[provider].name} isn't set up: set ${name} in wrangler.jsonc.`);
  return text;
}

// MARK: Installations

/// Registers the Mac whose key signed the call (201), or, the same key again, keeps its
/// installation and its hostname (200). A new key brings `signIn` and `signInCode`: the state of a
/// sign-in it started and the code its sheet came back with from Apple or Google, used once; the
/// installation belongs to that account. An account that has PER_ACCOUNT.installations Macs
/// already loses the one it used longest ago (`evicted`), so a person with a new Mac isn't stuck.
/// This is no recovery from a stolen account: an attacker who keeps calling stays the most
/// recently used, so the owner's own Macs go first. A stolen account is recovered at Apple or Google; what
/// it can reach here is only remote access (a hostname to a gateway that needs a paired device's
/// token), never a token or data.
async function register(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
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
  const state = typeof call.body.signIn === "string" ? call.body.signIn : "";
  const code = typeof call.body.signInCode === "string" ? call.body.signInCode : "";
  const seconds = Math.floor(now().getTime() / 1000);
  const signIn = await env.DB.prepare(
    `SELECT s.sub, s.code_hash, u.limit_domain, u.workspace_domain, u.workspace_domain IS NOT NULL AS workspace FROM sign_ins s JOIN users u ON u.sub = s.sub
     WHERE s.state = ?1 AND s.public_key = ?2 AND s.used_at IS NULL AND s.expires_at > ?3`,
  )
    .bind(state, call.key, seconds)
    .first<{ sub: string; code_hash: string; limit_domain: string | null; workspace_domain: string | null; workspace: number }>();
  if (!signIn || !code || (await sha256Hex(code)) !== signIn.code_hash) throw new Reply(403, "Sign in with Apple or Google first.");
  // Checked again here: MEMBER_WORKSPACES may have changed since the sign-in.
  if (!isMember(env, signIn.workspace_domain)) throw new Reply(403, `This Oby is for ${memberWorkspaces(env).join(", ")} accounts only.`);
  await spend(env.DB, call);
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const counted = [`registrations:account:${signIn.sub}`, `registrations:address:${addressBucket(address)}`, `registrations:network:${networkBucket(address)}`];
  await limit(env.DB, counted[0]!, LIMITS.registrationsPerAccount, now(), "This account set up too many Macs today.");
  await limit(env.DB, counted[1]!, LIMITS.registrationsPerAddress, now(), "Too many Macs were set up from this network lately.");
  await limit(env.DB, counted[2]!, LIMITS.registrationsPerNetwork, now(), "Too many Macs were set up from this network lately.");
  const domain = signIn.limit_domain;
  if (domain) {
    counted.push(`registrations:domain:${domain}`);
    const allowance = { max: domainAllowance(env, !!signIn.workspace).registrations, windowSeconds: 24 * 60 * 60 };
    // Looked at before it's taken: a refused try (a personal account on a Workspace's addresses,
    // past the smaller allowance) doesn't spend what the Workspace's own accounts may use.
    if ((await countedSoFar(env.DB, counted[3]!, allowance, now())) >= allowance.max) throw new Reply(429, `Accounts at ${domain} set up too many Macs today. Try again tomorrow.`);
    await limit(env.DB, counted[3]!, allowance, now(), `Accounts at ${domain} set up too many Macs today.`);
  }
  // ponytail: counted, then inserted: two registrations at once for one account can both find
  // room and leave it a Mac over PER_ACCOUNT.installations; registrationsPerAccount bounds that.
  const theirs = await env.DB.prepare("SELECT * FROM installations WHERE user_sub = ?1 ORDER BY last_seen_at").bind(signIn.sub).all<InstallationRow>();
  let evicted: { name: string } | undefined;
  if (theirs.results.length >= PER_ACCOUNT.installations) {
    const oldest = theirs.results[0]!;
    try {
      await remove(env.DB, deps.tunnels, oldest);
    } catch (error) {
      // Cloudflare refused: nothing changed, so this try isn't counted and the sign-in, not claimed
      // yet, works again.
      await env.DB.batch(counted.map((key) => env.DB.prepare("UPDATE rate_limits SET count = count - 1 WHERE key = ?1 AND count > 0").bind(key)));
      throw error;
    }
    evicted = { name: oldest.name };
  }
  // Used once: a second registration with the same sign-in finds nothing.
  const claimed = await env.DB.prepare("UPDATE sign_ins SET used_at = ?2 WHERE state = ?1 AND used_at IS NULL RETURNING state").bind(state, at).first();
  if (!claimed) throw new Reply(403, "Sign in with Apple or Google first.");
  const row: InstallationRow = { id: newId(), public_key: call.key, user_sub: signIn.sub, name, platform, created_at: at, last_seen_at: at };
  // Two calls at once with one key: the first one's row stands, and both answer with it.
  await env.DB.prepare(
    "INSERT INTO installations (id, public_key, user_sub, name, platform, created_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT (public_key) DO NOTHING",
  )
    .bind(row.id, row.public_key, row.user_sub, row.name, row.platform, row.created_at, row.last_seen_at)
    .run();
  const saved = await byKey(env.DB, call.key);
  if (!saved) throw new Error("The installation couldn't be saved.");
  return json({ installation: await publicInstallation(env.DB, saved), ...(evicted ? { evicted } : {}) }, saved.id === row.id ? 201 : 200);
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
  const waiting = (await env.DB.prepare("SELECT count(*) AS n FROM endpoints WHERE network = ?1 AND connected_at IS NULL").bind(network).first<{ n: number }>())?.n ?? 0;
  if (waiting >= UNCONNECTED_PER_NETWORK) throw new Reply(429, "Too many Macs on this network are turning remote access on right now. Try again in an hour.");
  // Creating, then removing, is what costs Cloudflare calls and the global limit: each
  // installation and each network may make only a few a day, so a few networks can't drain
  // `endpointsEverywhere` for everyone.
  // Every installation has an account since Sign in with Apple; one without is refused, never
  // spared the account's limits.
  if (!row.user_sub) throw new Reply(403, "Sign in again: turn remote access off and on.");
  {
    const theirs = (await env.DB.prepare("SELECT count(*) AS n FROM endpoints e JOIN installations i ON i.id = e.installation_id WHERE i.user_sub = ?1").bind(row.user_sub).first<{ n: number }>())?.n ?? 0;
    if (theirs >= PER_ACCOUNT.endpoints) throw new Reply(409, `This account has ${PER_ACCOUNT.endpoints} Macs with remote access on already. Forget one first.`);
    const owner = await env.DB.prepare("SELECT limit_domain, workspace_domain IS NOT NULL AS workspace FROM users WHERE sub = ?1")
      .bind(row.user_sub)
      .first<{ limit_domain: string | null; workspace: number }>();
    const domain = owner?.limit_domain;
    if (domain) {
      // A Workspace account counts against its Workspace's allowance, any other against the email
      // domain's, over every endpoint under the domain: someone with personal accounts on a
      // company's addresses can't push past the smaller one.
      const allowed = domainAllowance(env, !!owner.workspace).endpoints;
      const shared =
        (
          await env.DB.prepare("SELECT count(*) AS n FROM endpoints e JOIN installations i ON i.id = e.installation_id JOIN users u ON u.sub = i.user_sub WHERE u.limit_domain = ?1")
            .bind(domain)
            .first<{ n: number }>()
        )?.n ?? 0;
      if (shared >= allowed) throw new Reply(409, `Accounts at ${domain} have ${allowed} Macs with remote access on already. Forget one first.`);
    }
  }
  await limitEndpointChanges(env.DB, row, now());
  await limit(env.DB, `creations:installation:${row.id}`, LIMITS.creationsPerInstallation, now(), "This Mac turned remote access on too often today.");
  await limit(env.DB, `creations:account:${row.user_sub}`, LIMITS.creationsPerAccount, now(), "This account turned remote access on too often today.");
  await limit(env.DB, `creations:network:${network}`, LIMITS.creationsPerNetworkHour, now(), "Too many Macs on this network turned remote access on lately.");
  await limit(env.DB, `creations:network-day:${network}`, LIMITS.creationsPerNetworkDay, now(), "Too many Macs on this network turned remote access on today.");
  await limit(env.DB, "endpoints:everywhere", LIMITS.endpointsEverywhere, now(), "Too many Macs are turning remote access on right now.");
  const hostname = `${env.HOSTNAME_PREFIX}${opaqueLabel()}.${domain}`;
  const tunnel = await deps.tunnels.createTunnel(`oby-${row.id}`, tunnelSecret());
  try {
    // Only the gateway, and nothing else on the Mac, is reachable through the tunnel.
    await deps.tunnels.configureTunnel(tunnel.id, [{ hostname, service: env.GATEWAY }, { service: "http_status:404" }]);
    const record = await deps.tunnels.createCNAME(hostname, `${tunnel.id}.cfargotunnel.com`);
    const endpoint: EndpointRow = { installation_id: row.id, tunnel_id: tunnel.id, hostname, dns_record_id: record.id, created_at: iso(now()), network, checked_at: null, connected_at: null };
    try {
      await env.DB.batch([
        env.DB.prepare("INSERT INTO endpoints (installation_id, tunnel_id, hostname, dns_record_id, created_at, network) VALUES (?1, ?2, ?3, ?4, ?5, ?6)").bind(
          endpoint.installation_id,
          endpoint.tunnel_id,
          endpoint.hostname,
          endpoint.dns_record_id,
          endpoint.created_at,
          network,
        ),
        env.DB.prepare("UPDATE installations SET endpoint_at = COALESCE(endpoint_at, ?2) WHERE id = ?1").bind(row.id, endpoint.created_at),
      ]);
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
  // Anyone who signs in gets a hostname: under the product's domain, a stranger's page could get it
  // flagged or set its cookies. Only a members-only instance may share it (MEMBER_WORKSPACES).
  if (devices === products && !memberWorkspaces(env).length) {
    throw new Reply(503, "DEVICE_DOMAIN can't share the product's registrable domain unless MEMBER_WORKSPACES makes this instance members-only: register a domain of its own, or set MEMBER_WORKSPACES.");
  }
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

/// The DNS record and the tunnel go at Cloudflare first, then the row: if Cloudflare refuses,
/// the endpoint stays and the call fails, so nothing is left behind unknown.
async function tearDown(db: D1Database, tunnels: TunnelAPI, endpoint: EndpointRow): Promise<void> {
  await tunnels.deleteDNSRecord(endpoint.dns_record_id);
  await tunnels.deleteTunnel(endpoint.tunnel_id);
  await db.prepare("DELETE FROM endpoints WHERE installation_id = ?1").bind(endpoint.installation_id).run();
}

/// The installation, its hooks and its endpoint; the endpoint at Cloudflare first, so a refusal
/// keeps all three.
async function remove(db: D1Database, tunnels: TunnelAPI, row: InstallationRow): Promise<void> {
  const endpoint = await endpointOf(db, row.id);
  if (endpoint) await tearDown(db, tunnels, endpoint);
  await db.batch([
    db.prepare("DELETE FROM hook_queue WHERE installation_id = ?1").bind(row.id),
    db.prepare("DELETE FROM hooks WHERE installation_id = ?1").bind(row.id),
    db.prepare("DELETE FROM installations WHERE id = ?1").bind(row.id),
  ]);
}

// MARK: Hooks (#1128)

interface HookRow {
  id: string;
  installation_id: string;
  created_at: string;
}

function publicHook(request: Request, row: HookRow) {
  return { id: row.id, url: `${new URL(request.url).origin}/h/${row.id}`, createdAt: row.created_at };
}

/// A new hook address for this Mac: an unguessable id (about 165 bits), at most
/// HOOKS_PER_INSTALLATION at once and 20 made a day.
async function createHook(request: Request, env: Env, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const count = (await env.DB.prepare("SELECT count(*) AS n FROM hooks WHERE installation_id = ?1").bind(row.id).first<{ n: number }>())?.n ?? 0;
  if (count >= HOOKS_PER_INSTALLATION) throw new Reply(409, `This Mac has ${HOOKS_PER_INSTALLATION} hooks already. Remove one first.`);
  await limit(env.DB, `hooks:installation:${row.id}`, LIMITS.hooksMadePerInstallation, now(), "This Mac made too many hooks today.");
  const hook: HookRow = { id: opaqueLabel(32), installation_id: row.id, created_at: iso(now()) };
  await env.DB.prepare("INSERT INTO hooks (id, installation_id, created_at) VALUES (?1, ?2, ?3)").bind(hook.id, hook.installation_id, hook.created_at).run();
  return json({ hook: publicHook(request, hook) }, 201);
}

async function listHooks(request: Request, env: Env, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const hooks = await env.DB.prepare("SELECT * FROM hooks WHERE installation_id = ?1 ORDER BY created_at").bind(row.id).all<HookRow>();
  return json({ hooks: hooks.results.map((hook) => publicHook(request, hook)) });
}

async function removeHook(request: Request, env: Env, now: () => Date, id: string): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  // What was kept for it goes with it.
  const [, gone] = await env.DB.batch([
    env.DB.prepare("DELETE FROM hook_queue WHERE hook_id = ?1 AND installation_id = ?2").bind(id, row.id),
    env.DB.prepare("DELETE FROM hooks WHERE id = ?1 AND installation_id = ?2").bind(id, row.id),
  ]);
  if (!gone?.meta.changes) throw new Reply(404, "This Mac has no such hook.");
  return new Response(null, { status: 204 });
}

/// A sender's delivery: checked for what needs no secret (the hook, the size, the rate), then passed
/// to the Mac's gateway with the body as it came and only HOOK_HEADERS. obid checks the
/// signature with the secret only it holds. The sender gets obid's status with a fixed body of the
/// Worker's own, so nothing obid says reaches it. With the Mac away, it's kept sealed (`keep`);
/// nothing of a delivery is logged.
async function deliver(request: Request, env: Env, deps: Deps, now: () => Date, id: string): Promise<Response> {
  const hook = /^[a-z0-9]{32}$/.test(id) ? await env.DB.prepare("SELECT * FROM hooks WHERE id = ?1").bind(id).first<HookRow>() : null;
  if (!hook) throw new Reply(404, "No such hook.");
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > HOOK_BODY_MAX) throw new Reply(413, "That delivery is too large.");
  const body = await boundedBody(request, HOOK_BODY_MAX);
  if (!body) throw new Reply(413, "That delivery is too large.");
  await limit(env.DB, `deliveries:minute:${id}`, LIMITS.deliveriesPerHookMinute, now(), "Too many deliveries to this hook.");
  // The day's allowance is spent only by deliveries obid doesn't refuse as unsigned (below), so a
  // stranger's junk can't use it up for the real sender.
  const day = `deliveries:day:${id}`;
  if ((await countedSoFar(env.DB, day, LIMITS.deliveriesPerHookDay, now())) >= LIMITS.deliveriesPerHookDay.max) {
    throw new Reply(429, "Too many deliveries to this hook today. Try again tomorrow.");
  }
  const headers = new Headers();
  for (const name of HOOK_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  const endpoint = await endpointOf(env.DB, hook.installation_id);
  const forward = deps.forward ?? ((url: string, init: RequestInit) => fetch(url, init));
  let status = 0;
  if (endpoint) {
    try {
      const answer = await forward(`https://${endpoint.hostname}/v1/hooks/${id}/deliver`, {
        method: "POST",
        headers,
        body,
        redirect: "manual",
        signal: AbortSignal.timeout(HOOK_WAIT_MS),
      });
      status = answer.status;
    } catch {
      // The Mac didn't answer: kept below.
    }
  }
  // Cloudflare's own answers for a tunnel that's down (502, 530 and the like) are the Mac away.
  if (status >= 500 || status < 200 || (status >= 300 && status < 400)) return keep(env, now, hook, headers, body);
  if (status !== 401) await takeOne(env.DB, day, LIMITS.deliveriesPerHookDay, now());
  console.log(`hook ${id}: ${status}`);
  return json({ ok: status < 300 }, status);
}

/// The Mac is away (#1315): the delivery is kept, sealed to its obid's queue key, for QUEUE.hours,
/// and the sender gets 202 so it doesn't retry into a growing pile. With no queue key, or past a
/// bound, nothing is kept and the answer is 503, as before. What's kept is unverified until obid
/// opens it and checks it as a live one.
async function keep(env: Env, now: () => Date, hook: HookRow, headers: Headers, body: Uint8Array): Promise<Response> {
  const away = new Reply(503, "That Oby isn't reachable now.");
  const owner = await env.DB.prepare("SELECT queue_key FROM installations WHERE id = ?1").bind(hook.installation_id).first<{ queue_key: string | null }>();
  const key = owner?.queue_key ? fromBase64url(owner.queue_key) : null;
  if (!key || body.byteLength > QUEUE.bodyMax) throw away;
  const total = whole(env.QUEUE_TOTAL_MIB, "QUEUE_TOTAL_MIB", 1, 10_000) * 1024 * 1024;
  const plain = new TextEncoder().encode(JSON.stringify({ receivedAt: iso(now()), headers: Object.fromEntries(headers), body: base64(body) }));
  const sealed = await seal(key, hook.id, plain);
  // ponytail: counted, then inserted: deliveries at once can overshoot a bound by a few; the
  // per-hook rates keep that small.
  const [theirs, everyone] = await env.DB.batch<{ n: number; bytes: number }>([
    env.DB.prepare("SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM hook_queue WHERE installation_id = ?1").bind(hook.installation_id),
    env.DB.prepare("SELECT count(*) AS n, coalesce(sum(size), 0) AS bytes FROM hook_queue"),
  ]);
  const mine = theirs?.results[0] ?? { n: 0, bytes: 0 };
  const all = (everyone?.results[0]?.bytes ?? 0) + sealed.byteLength;
  if (mine.n >= QUEUE.perInstallation || mine.bytes + sealed.byteLength > QUEUE.bytesPerInstallation || all > total) throw away;
  await env.DB.prepare("INSERT INTO hook_queue (id, hook_id, installation_id, received_at, size, sealed) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    .bind(opaqueLabel(32), hook.id, hook.installation_id, iso(now()), sealed.byteLength, sealed)
    .run();
  // Kept, so it counts against the hook's day as a delivery obid takes does.
  await takeOne(env.DB, `deliveries:day:${hook.id}`, LIMITS.deliveriesPerHookDay, now());
  // Workers Logs keep it, as MAX_ENDPOINTS's warning.
  if (all >= total * 0.8) console.warn(`hook queue: ${all} of ${total} bytes kept, past 80% of QUEUE_TOTAL_MIB`);
  console.log(`hook ${hook.id}: kept, ${sealed.byteLength} bytes`);
  return json({ ok: true, message: "Kept for that Oby." }, 202);
}

/// Seals `plain` to `queueKey` (an uncompressed P-256 point) so only the obid holding its private
/// half can open it: an ephemeral P-256 key, ECDH, HKDF-SHA-256 (salt: the ephemeral public key
/// then `queueKey`; info QUEUE_INFO) to an AES-256-GCM key, a random 96-bit nonce, and the hook's id
/// as associated data. The box: the ephemeral public key (65 bytes), the nonce (12), then the
/// ciphertext and its tag.
export async function seal(queueKey: Uint8Array, hook: string, plain: Uint8Array): Promise<Uint8Array> {
  const curve = { name: "ECDH", namedCurve: "P-256" };
  const peer = await crypto.subtle.importKey("raw", queueKey, curve, false, []);
  const ephemeral = (await crypto.subtle.generateKey(curve, true, ["deriveBits"])) as CryptoKeyPair;
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: peer } as SubtleCryptoDeriveKeyAlgorithm, ephemeral.privateKey, 256);
  const mine = new Uint8Array((await crypto.subtle.exportKey("raw", ephemeral.publicKey)) as ArrayBuffer);
  const base = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const salt = joined(mine, queueKey);
  const info = new TextEncoder().encode(QUEUE_INFO);
  const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt, info }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const nonce = randomBytes(12);
  const box = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(hook) }, key, plain);
  return joined(mine, nonce, new Uint8Array(box));
}

function joined(...parts: Uint8Array[]): Uint8Array {
  const all = new Uint8Array(parts.reduce((n, part) => n + part.byteLength, 0));
  let at = 0;
  for (const part of parts) {
    all.set(part, at);
    at += part.byteLength;
  }
  return all;
}

/// The Mac registers its obid's queue key (#1315): `{"key": <X9.63, base64url>}`, a P-256 point.
async function setQueueKey(request: Request, env: Env, now: () => Date): Promise<Response> {
  const { row, body } = await signedCall(request, env, now);
  const key = typeof body.key === "string" ? canonicalKey(body.key) : null;
  if (!key) throw new Reply(422, "key is a P-256 public key: X9.63, base64url.");
  // A point not on the curve is refused now, not when the first delivery is sealed to it.
  try {
    await crypto.subtle.importKey("raw", fromBase64url(key)!, { name: "ECDH", namedCurve: "P-256" }, false, []);
  } catch {
    throw new Reply(422, "key is a P-256 public key: X9.63, base64url.");
  }
  await env.DB.prepare("UPDATE installations SET queue_key = ?2 WHERE id = ?1").bind(row.id, key).run();
  return new Response(null, { status: 204 });
}

/// What was kept for this Mac, oldest first, QUEUE.batch at a time, sealed as kept; and how many
/// more there are.
async function keptItems(request: Request, env: Env, now: () => Date): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const [items, count] = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare("SELECT id, hook_id, received_at, sealed FROM hook_queue WHERE installation_id = ?1 ORDER BY received_at, id LIMIT ?2").bind(row.id, QUEUE.batch),
    env.DB.prepare("SELECT count(*) AS n FROM hook_queue WHERE installation_id = ?1").bind(row.id),
  ]);
  const listed = (items?.results ?? []).map((item) => ({
    id: item.id,
    hook: item.hook_id,
    receivedAt: item.received_at,
    sealed: base64url(new Uint8Array(item.sealed as ArrayBuffer)),
  }));
  return json({ items: listed, left: Number(count?.results[0]?.n ?? 0) - listed.length }, 200, noStore);
}

/// The Mac handed one to obid: it goes.
async function removeKept(request: Request, env: Env, now: () => Date, id: string): Promise<Response> {
  const row = await signedInstallation(request, env, now);
  const gone = await env.DB.prepare("DELETE FROM hook_queue WHERE id = ?1 AND installation_id = ?2").bind(id, row.id).run();
  if (!gone.meta.changes) throw new Reply(404, "This Mac has no such kept delivery.");
  return new Response(null, { status: 204 });
}

/// The request's body, read as a stream and cut off past `max` bytes (null then): never buffered
/// whole when it's too large.
async function boundedBody(request: Request, max: number): Promise<Uint8Array | null> {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      return null;
    }
    parts.push(value);
  }
  const body = new Uint8Array(size);
  let at = 0;
  for (const part of parts) {
    body.set(part, at);
    at += part.byteLength;
  }
  return body;
}

// MARK: The push relay (#398)

const notSetUp = "Pushes aren't set up on this control plane.";
const wrongSecret = "That pushId and pushSecret don't go together.";
const phoneGone = "That phone isn't registered for pushes any more.";

/// An iPhone registers its APNs token (`{apns, topic, sandbox}`, as `application/json`, so a web
/// page can't register for its visitors without a CORS preflight, which this Worker refuses) and
/// gets `{pushId, pushSecret}`; it gives its obid the pushId and the pushKey made from the secret
/// (`pushKey`). The same call with them added registers a changed token for the same id, and
/// brings back one the relay forgot: the secret proves it's that phone's. A token new to the
/// relay is checked with Apple first (one background push), so what's kept is a real phone's. A
/// token another pushId has moves to this one, so one phone never gets two of each push.
async function registerPhone(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const apns = relayAPNs(env, deps);
  const topics = (env.APNS_TOPICS ?? "").split(",").map((topic) => topic.trim()).filter(Boolean);
  if (!topics.length) throw new Reply(503, notSetUp);
  if ((request.headers.get("Content-Type") ?? "").split(";")[0]?.trim().toLowerCase() !== "application/json") {
    throw new Reply(415, "Send the registration as application/json.");
  }
  const body = only(await smallJSON(request, PUSH.registrationMax), ["apns", "topic", "sandbox", "pushId", "pushSecret"]);
  const token = field(body.apns, "apns", /^(?:[0-9a-fA-F]{2}){32,100}$/, "the APNs device token, in hex").toLowerCase();
  if (typeof body.topic !== "string" || !topics.includes(body.topic)) throw new Reply(422, `topic is ${topics.join(" or ")}.`);
  if (typeof body.sandbox !== "boolean") throw new Reply(422, "sandbox is true or false.");
  let id: string;
  if (body.pushId !== undefined || body.pushSecret !== undefined) {
    if (typeof body.pushId !== "string" || !(await secretMatches(env, body.pushId, body.pushSecret))) throw new Reply(401, wrongSecret);
    id = body.pushId;
    await relayLimit(env.DB, "again", id, LIMITS.reRegistrationsPerPhone, now(), "This phone registered too often lately.");
  } else {
    const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const busy = "Too many phones registered from this network lately.";
    await relayLimit(env.DB, "address", addressBucket(address), LIMITS.phonesPerAddress, now(), busy);
    await relayLimit(env.DB, "network", networkBucket(address), LIMITS.phonesPerNetwork, now(), busy);
    await relayLimit(env.DB, "everywhere", "", LIMITS.phonesEverywhere, now(), "Too many phones registered lately.");
    const max = whole(env.MAX_PUSH_DEVICES, "MAX_PUSH_DEVICES", 1, 100_000_000);
    const count = (await env.DB.prepare("SELECT n FROM push_device_count WHERE id = 1").first<{ n: number }>())?.n ?? 0;
    if (count >= max) throw new Reply(503, "This control plane can't take more phones now.");
    // Workers Logs keep it, as MAX_ENDPOINTS's warning.
    if (count + 1 >= max * 0.8) console.warn(`push relay: ${count + 1} of ${max} phones, past 80% of MAX_PUSH_DEVICES`);
    id = base64url(randomBytes(18));
  }
  const known = await env.DB.prepare("SELECT 1 AS yes FROM push_devices WHERE id = ?1 AND apns_token = ?2").bind(id, token).first();
  if (!known) {
    await relayLimit(env.DB, "check", await sha256Hex(token), LIMITS.tokenChecksPerToken, now(), "This token was checked too often lately.");
    const payload = JSON.stringify({ aps: { "content-available": 1 } });
    const answer = await sendPush(apns, { token, topic: body.topic, sandbox: body.sandbox, type: "background", payload, urgent: false }, now());
    if (answer.status !== 200) {
      if (tokenGone(answer)) throw new Reply(422, "Apple doesn't know that device token for this app. Check `sandbox`.");
      appleFailed(answer, "check");
    }
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM push_devices WHERE apns_token = ?1 AND id <> ?2").bind(token, id),
    env.DB.prepare(
      `INSERT INTO push_devices (id, apns_token, topic, sandbox) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (id) DO UPDATE SET apns_token = excluded.apns_token, topic = excluded.topic, sandbox = excluded.sandbox`,
    ).bind(id, token, body.topic, body.sandbox ? 1 : 0),
  ]);
  return json({ pushId: id, pushSecret: await pushSecret(env, id) }, 200, noStore);
}

/// The phone forgets itself: `Authorization: Bearer <pushSecret>`. 204, also when it was gone.
/// obid holds only the pushKey, so it can't.
async function forgetPhone(request: Request, env: Env, id: string): Promise<Response> {
  pushSecretKey(env);
  const bearer = /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "")?.[1];
  if (!(await secretMatches(env, id, bearer))) throw new Reply(401, wrongSecret);
  await env.DB.prepare("DELETE FROM push_devices WHERE id = ?1").bind(id).run();
  return new Response(null, { status: 204 });
}

/// obid's push: `{pushId, sealed, collapse?, urgent?, at}` with `Oby-Push-Mac`, the HMAC-SHA-256
/// of the body's bytes under the pushKey's 32 raw bytes, base64url; `at` (Unix seconds, in the body, so
/// the MAC covers it) within PUSH_SKEW_SECONDS of the relay's clock. The MAC is checked before
/// anything is read or counted, so a stranger's push costs no D1 and can't spend the phone's
/// allowance. Apple gets the fixed alert with `sealed` beside `aps`; Apple saying the token is gone
/// forgets the phone (410). Nothing of a push is kept or logged but Apple's status and reason, and
/// the counts the rate limits need.
async function push(request: Request, env: Env, deps: Deps, now: () => Date): Promise<Response> {
  const apns = relayAPNs(env, deps);
  if (Number(request.headers.get("Content-Length") ?? "0") > PUSH.bodyMax) throw new Reply(413, "That push is too large.");
  const raw = await boundedBody(request, PUSH.bodyMax);
  if (!raw) throw new Reply(413, "That push is too large.");
  const body = only(parseJSON(raw), ["pushId", "sealed", "collapse", "urgent", "at"]);
  const id = field(body.pushId, "pushId", PUSH_ID, "the phone's pushId");
  const sealed = field(body.sealed, "sealed", /^[A-Za-z0-9_-]+$/, "the sealed alert, base64url");
  if (sealed.length > PUSH.sealedMax) throw new Reply(413, `sealed is at most ${PUSH.sealedMax} characters.`);
  const collapse = body.collapse === undefined ? undefined : field(body.collapse, "collapse", /^[\x21-\x7e]{1,64}$/, "1 to 64 printable characters, no spaces");
  if (body.urgent !== undefined && typeof body.urgent !== "boolean") throw new Reply(422, "urgent is true or false.");
  if (typeof body.at !== "number" || !Number.isSafeInteger(body.at)) throw new Reply(422, "at is the push's time, in Unix seconds.");
  if (!(await macMatches(env, id, request.headers.get("Oby-Push-Mac"), raw))) throw new Reply(401, "This push isn't signed with that phone's pushKey.");
  if (Math.abs(body.at - Math.floor(now().getTime() / 1000)) > PUSH_SKEW_SECONDS) throw new Reply(401, "This push's `at` is more than five minutes from the relay's clock.");
  const many = "Too many pushes to this phone.";
  await relayLimit(env.DB, "id", id, LIMITS.pushesPerPhoneMinute, now(), many);
  await relayLimit(env.DB, "id", id, LIMITS.pushesPerPhoneDay, now(), `${many} today`);
  const phone = await env.DB.prepare("SELECT apns_token, topic, sandbox FROM push_devices WHERE id = ?1").bind(id)
    .first<{ apns_token: string; topic: string; sandbox: number }>();
  if (!phone) throw new Reply(410, phoneGone);
  // Per token too: the same phone registered under new pushIds shares one allowance.
  const hashed = await sha256Hex(phone.apns_token);
  await relayLimit(env.DB, "token", hashed, LIMITS.pushesPerPhoneMinute, now(), many);
  await relayLimit(env.DB, "token", hashed, LIMITS.pushesPerPhoneDay, now(), `${many} today`);
  const payload = JSON.stringify({ aps: { alert: PUSH_ALERT, "mutable-content": 1, sound: "default" }, sealed });
  const answer = await sendPush(apns, { token: phone.apns_token, topic: phone.topic, sandbox: phone.sandbox === 1, type: "alert", payload, urgent: body.urgent === true, collapse }, now());
  if (answer.status === 200) return json({ ok: true });
  if (tokenGone(answer)) {
    console.log(`push: APNs ${answer.status} ${answer.reason ?? ""}, phone forgotten`);
    // Only that token: the phone may have registered a new one meanwhile.
    await env.DB.prepare("DELETE FROM push_devices WHERE id = ?1 AND apns_token = ?2").bind(id, phone.apns_token).run();
    throw new Reply(410, phoneGone);
  }
  appleFailed(answer, "push");
}

/// Apple saying a device token is gone: the app was deleted, or it isn't this app's or this
/// environment's.
function tokenGone(answer: APNsAnswer): boolean {
  return answer.status === 410 || (answer.status === 400 && (answer.reason === "BadDeviceToken" || answer.reason === "DeviceTokenNotForTopic"));
}

/// Any other answer than 200, logged by its status and reason only, as an error to send back:
/// the relay's own problems (its provider token renewed too often, Apple down) apart from the
/// phone's (too many pushes to it).
function appleFailed(answer: APNsAnswer, what: "push" | "check"): never {
  console.log(`${what}: APNs ${answer.status || "didn't answer"}${answer.reason ? ` ${answer.reason}` : ""}`);
  if (answer.status === 429 && answer.reason === "TooManyProviderTokenUpdates") throw new Reply(503, "The relay's sign-in with Apple was renewed too often. Try again in a while.");
  if (answer.status === 429) throw new Reply(429, "Apple says too many pushes to this phone. Try again later.", answer.retryAfter ? { "Retry-After": answer.retryAfter } : {});
  if (answer.status === 0 || answer.status >= 500) throw new Reply(502, "Apple didn't answer. Try again later.");
  throw new Reply(502, `Apple refused the ${what === "push" ? "push" : "token check"}${answer.reason ? `: ${answer.reason}` : ""}.`);
}

/// What sending to Apple needs, or the relay is off (503).
function relayAPNs(env: Env, deps: Deps): APNs {
  const secret = pushSecretKey(env);
  const key = apnsKey(env);
  if (!key) throw new Reply(503, notSetUp);
  return { send: deps.apns ?? ((url: string, init: RequestInit) => fetch(url, init)), key, db: env.DB, secret };
}

/// One of the relay's rate limits: its window aligned to whole minutes, hours or days, and its
/// window's length in the key, so the sweep removes it as soon as it ends (`sweep`). It keeps a
/// count and which window it counts, never when a push or registration came.
async function relayLimit(db: D1Database, what: string, of: string, rule: Limit, now: Date, said: string): Promise<void> {
  const verdict = await takeOne(db, `push:${rule.windowSeconds}:${what}:${of}`, rule, now, true);
  if (verdict.allowed) return;
  const minutes = Math.ceil(verdict.retryAfterSeconds / 60);
  throw new Reply(429, `${said} Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`, { "Retry-After": String(verdict.retryAfterSeconds) });
}

/// PUSH_SECRET_KEY, or the relay is off (503).
function pushSecretKey(env: Env): string {
  const key = env.PUSH_SECRET_KEY?.trim() ?? "";
  if (key.length < 32) throw new Reply(503, notSetUp);
  return key;
}

/// HMAC-SHA-256 of `message` under the raw bytes `key`, base64url with no padding. A pushSecret's
/// or a pushKey's raw bytes are its base64url decoded (32 bytes), never its text.
async function hmac(key: Uint8Array, message: Uint8Array): Promise<string> {
  const imported = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", imported, message)));
}

/// A phone's pushSecret: the HMAC of PUSH_SECRET_INFO, a newline and its pushId, under
/// PUSH_SECRET_KEY's text (the relay's own, so no one else makes it), made again whenever it's
/// needed, so D1 keeps no secret.
async function pushSecret(env: Env, id: string): Promise<string> {
  return hmac(new TextEncoder().encode(pushSecretKey(env)), new TextEncoder().encode(`${PUSH_SECRET_INFO}\n${id}`));
}

/// The pushKey the phone gives obid: the HMAC of PUSH_KEY_INFO under the pushSecret's 32 raw
/// bytes. obid signs pushes with it, and can't register or forget the phone.
async function pushKey(env: Env, id: string): Promise<string> {
  return hmac(fromBase64url(await pushSecret(env, id))!, new TextEncoder().encode(PUSH_KEY_INFO));
}

/// Whether two texts are the same, compared in constant time.
function sameText(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  return a.byteLength === b.byteLength && crypto.subtle.timingSafeEqual(a, b);
}

/// Whether `secret` is `id`'s pushSecret.
async function secretMatches(env: Env, id: string, secret: unknown): Promise<boolean> {
  if (typeof secret !== "string" || !PUSH_ID.test(id)) return false;
  return sameText(secret, await pushSecret(env, id));
}

/// Whether `mac` is the HMAC of `body` under `id`'s pushKey's 32 raw bytes.
async function macMatches(env: Env, id: string, mac: string | null, body: Uint8Array): Promise<boolean> {
  if (!mac) return false;
  return sameText(mac, await hmac(fromBase64url(await pushKey(env, id))!, body));
}

/// A JSON object of at most `max` bytes (413 past it).
async function smallJSON(request: Request, max: number): Promise<Record<string, unknown>> {
  if (Number(request.headers.get("Content-Length") ?? "0") > max) throw new Reply(413, "That's too large.");
  const raw = await boundedBody(request, max);
  if (!raw) throw new Reply(413, "That's too large.");
  return parseJSON(raw);
}

/// `body`, when it has no field but `names` (422 otherwise).
function only(body: Record<string, unknown>, names: string[]): Record<string, unknown> {
  if (Object.keys(body).some((name) => !names.includes(name))) throw new Reply(422, `This call takes only ${names.join(", ")}.`);
  return body;
}

// MARK: The sweep

/// Cron's job, every minute (wrangler.jsonc): spent nonces, rate-limit windows a day old (the push
/// relay's as soon as they end) and deliveries kept past QUEUE.hours go;
/// installations that never made an endpoint go after UNUSED_HOURS, in one statement; up to
/// SWEEP_BATCH installations no Mac has signed a call for in IDLE_DAYS go with their tunnels and
/// hostnames; and STATUS_BATCH endpoints, never-checked first, are asked about at Cloudflare:
/// one never connected within an hour or down for days is reclaimed
/// (`reclaimable`). One that Cloudflare refuses is tried again next time.
export async function sweep(env: Env, deps: Deps): Promise<{ removed: number; reclaimed: number; failed: number; unused: number }> {
  const now = (deps.now ?? (() => new Date()))();
  const seconds = Math.floor(now.getTime() / 1000);
  const unusedBefore = iso(new Date(now.getTime() - UNUSED_HOURS * 3_600_000));
  const unusedOnes = "SELECT id FROM installations WHERE created_at < ?1 AND endpoint_at IS NULL AND NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.installation_id = installations.id)";
  const [, , , , , , unused] = await env.DB.batch([
    env.DB.prepare("DELETE FROM nonces WHERE expires_at < ?1").bind(seconds),
    env.DB.prepare("DELETE FROM sign_ins WHERE expires_at < ?1").bind(seconds),
    // Every window is an hour or less: a day-old one counts nothing.
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(seconds - 86_400),
    // Kept deliveries (#1315) last QUEUE.hours.
    env.DB.prepare("DELETE FROM hook_queue WHERE received_at < ?1").bind(iso(new Date(now.getTime() - QUEUE.hours * 3_600_000))),
    // Never made an endpoint: one whose endpoint was reclaimed stays (`endpoint_at`). What it kept
    // and its hooks go first.
    env.DB.prepare(`DELETE FROM hook_queue WHERE installation_id IN (${unusedOnes})`).bind(unusedBefore),
    env.DB.prepare(`DELETE FROM hooks WHERE installation_id IN (${unusedOnes})`).bind(unusedBefore),
    env.DB.prepare("DELETE FROM installations WHERE created_at < ?1 AND endpoint_at IS NULL AND NOT EXISTS (SELECT 1 FROM endpoints e WHERE e.installation_id = installations.id)").bind(unusedBefore),
    // The push relay's windows (`relayLimit`) go once they end, by their keys' range.
    ...[60, 3_600, 86_400].map((window) =>
      env.DB.prepare("DELETE FROM rate_limits WHERE key >= ?1 AND key < ?2 AND window_start <= ?3").bind(`push:${window}:`, `push:${window};`, seconds - window),
    ),
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
  // Never-checked first, oldest made first; then the longest ago checked.
  const due = await env.DB.prepare("SELECT * FROM endpoints ORDER BY checked_at IS NOT NULL, checked_at, created_at LIMIT ?1").bind(STATUS_BATCH).all<EndpointRow>();
  for (const endpoint of due.results) {
    await attempt(async () => {
      const status = await deps.tunnels.tunnelStatus(endpoint.tunnel_id);
      const verdict = reclaimable(endpoint, status, now);
      if (verdict) {
        await tearDown(env.DB, deps.tunnels, endpoint);
        reclaimed++;
      } else {
        await env.DB.prepare("UPDATE endpoints SET checked_at = ?2, connected_at = COALESCE(connected_at, ?3) WHERE installation_id = ?1")
          .bind(endpoint.installation_id, iso(now), status.activeAt ? iso(now) : null)
          .run();
      }
    });
  }
  return { removed, reclaimed, failed, unused: unused?.meta.changes ?? 0 };
}

/// Whether an endpoint's tunnel isn't kept connected: "never" when it never came up (Cloudflare
/// has no `conns_active_at`, though it sets `conns_inactive_at` from the start) by
/// NEVER_CONNECTED_HOURS after the endpoint was made; "down" when it came up once and went down
/// DISCONNECTED_HOURS ago; null to keep it.
export function reclaimable(endpoint: { created_at: string }, status: TunnelStatus, now: Date): "never" | "down" | null {
  if (status.connected) return null;
  const hoursSince = (time: string) => (now.getTime() - Date.parse(time)) / 3_600_000;
  if (!status.activeAt) return hoursSince(endpoint.created_at) >= NEVER_CONNECTED_HOURS ? "never" : null;
  return hoursSince(status.inactiveAt ?? status.activeAt) >= DISCONNECTED_HOURS ? "down" : null;
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

/// The installation the signing key belongs to; it was seen now.
async function signedInstallation(request: Request, env: Env, now: () => Date): Promise<InstallationRow> {
  return (await signedCall(request, env, now)).row;
}

/// The same, with the call's JSON body.
async function signedCall(request: Request, env: Env, now: () => Date): Promise<{ row: InstallationRow; body: Record<string, unknown> }> {
  const call = await signed(request, env, now());
  const row = await byKey(env.DB, call.key);
  // 410, apart from 401 (a bad signature) and 404 (no such route): the Mac should register again.
  if (!row) throw new Reply(410, "This Mac isn't registered. Turn remote access on again.");
  await spend(env.DB, call);
  const at = iso(now());
  await env.DB.prepare("UPDATE installations SET last_seen_at = ?2 WHERE id = ?1").bind(row.id, at).run();
  return { row: { ...row, last_seen_at: at }, body: call.body };
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
  // The account it's signed in with, as Settings shows it: the provider, and for Google the
  // domain kept (its Workspace's, else its email's). Never an email: none is kept.
  const user = row.user_sub
    ? await db.prepare("SELECT provider, workspace_domain, email_domain FROM users WHERE sub = ?1").bind(row.user_sub)
        .first<{ provider: string; workspace_domain: string | null; email_domain: string | null }>()
    : null;
  return {
    id: row.id,
    account: user ? { provider: user.provider, domain: user.workspace_domain ?? user.email_domain } : null,
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

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function iso(date: Date): string {
  return date.toISOString();
}
