// The bodies of the eight scenario steps (e2e/SCENARIO.md, "The steps"), as e2e/run.mjs runs them:
// each entry of its `steps` calls the function here with its number. They use what the harness
// gives every step in `ctx`: `start` (every process goes through it), `env`, `runDir`, `live`,
// `fixture` and `spec` (obi-sphere's reference verifier, loaded by the preflight).
//
// The harness plays both owners: their keys are made here, in memory, for each run, and never
// written anywhere; so is the Sphere's operator token. Each obid's API token is written only to
// its own home/api-token (0600), where obid takes it from: never its environment. Text the obids
// and the Sphere send back (goals, findings, summaries) is data: compared, never acted on.
//
// This file is the Rust core's (docs/ARCHITECTURE.md, section 6): the scenario's fixed values come
// from the lead's scenario.mjs and fixture.mjs, the write check's definitions from snapshot.mjs.

import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { groupRunning } from "./processes.mjs";
import { FIXTURE, git, refs } from "./fixture.mjs";
import {
  ADMIN_SCOPES, BRIEF, CANARY, EXPECTED_DECISION, EXPECTED_FINDINGS, EXPECTED_RESULT, EXPIRES_IN,
  INBOX_ANSWER, INBOX_OPTIONS, OBI_SCOPES, OBIS, POLICY_RULES, SPHERE,
} from "./scenario.mjs";
import { SNAPSHOT_EXCLUDES, changes, snapshot } from "./snapshot.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const OBI_DIR = resolve(here, "..", "..");

const TOKEN_EXCHANGE = "urn:ietf:params:oauth:grant-type:token-exchange";
const JWT_TYPE = "urn:ietf:params:oauth:token-type:jwt";
const ZERO_HASH = "0".repeat(64);
// SCENARIO.md step 8.4.4: names no process may leave at the top of HOME or the system's temp.
const WATCHED_NAME = /^(obid|obi-|\.obi|\.wrangler|wrangler|\.claude)/;

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const show = (v) => {
  const text = JSON.stringify(v);
  return text && text.length > 400 ? `${text.slice(0, 400)}…` : text;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowSeconds = () => Math.floor(Date.now() / 1000);
const timestamp = (s) => new Date(s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

// Deep equality that ignores the order of object keys (JSON has none) but not of arrays.
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  return v;
}
const same = (a, b) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));

function freePort() {
  return new Promise((res, rej) => {
    const server = createServer();
    server.once("error", rej);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => res(port));
    });
  });
}

// "Within N seconds": `probe` every 250 ms until it answers something other than undefined; after
// N seconds the step fails with what the last probe said (`why` is told the last value and error).
async function within(seconds, probe, why) {
  const deadline = Date.now() + seconds * 1000;
  let last;
  let error;
  for (;;) {
    try {
      const value = await probe();
      if (value !== undefined) return value;
      error = undefined;
    } catch (e) {
      error = e;
    }
    if (Date.now() > deadline) throw new Error(`within ${seconds} seconds: ${why(last, error)}`);
    await sleep(250);
  }
}

// One HTTP call; answers {status, body} with the body parsed as JSON when it is JSON.
async function call(url, { method = "GET", token, body, form, timeoutMs = 30_000 } = {}) {
  const headers = {};
  let payload;
  if (token) headers.Authorization = `Bearer ${token}`;
  if (form) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    payload = new URLSearchParams(form).toString();
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(url, { method, headers, body: payload, signal: AbortSignal.timeout(timeoutMs) });
  const text = await res.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {}
  return { status: res.status, body: parsed };
}

function expect(r, status, what) {
  assert(r.status === status, `${what}: expected ${status}, got ${r.status} ${show(r.body)}`);
  return r.body;
}

// An owner key (Ed25519), in memory only.
function newKey(spec) {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const pub = publicKey.export({ format: "jwk" }).x;
  return { privateKey, publicKey: pub, keyId: spec.keyIdOf(pub) };
}

// An owner assertion signed by `owner` (identity.md 4.1); with `mayAct`, a delegation to that Obi.
function assertion(ctx, owner, scope, { lifetime = 300, mayAct } = {}) {
  const iat = nowSeconds();
  const claims = { iss: owner.id, sub: owner.id, aud: `obi-sphere:${ctx.sphereId}`, iat, exp: iat + lifetime, jti: randomUUID(), scope };
  if (mayAct) claims.may_act = { sub: mayAct };
  return ctx.spec.signJwt(claims, owner.key.privateKey, owner.key.keyId);
}

// The Sphere's API: `/v0.1/…` on its port.
const sphere = (ctx, path, options) => call(`${ctx.sphereUrl}/v0.1${path}`, options);

// A new admin token for one call (SCENARIO.md, "The steps": a new assertion every time).
async function adminToken(ctx) {
  const r = await sphere(ctx, "/oauth/token", {
    method: "POST",
    form: { grant_type: TOKEN_EXCHANGE, subject_token: assertion(ctx, ctx.owners.w, ADMIN_SCOPES), subject_token_type: JWT_TYPE },
  });
  return expect(r, 200, "the admin token").access_token;
}
const asAdmin = async (ctx, path, options = {}) => sphere(ctx, path, { ...options, token: await adminToken(ctx) });

// An obid's API: `/v1/…` on its port, with its token.
const obid = (ctx, which, path, options = {}) => call(`http://127.0.0.1:${ctx.obids[which].port}/v1${path}`, { ...options, token: ctx.obids[which].token });

// Every member's keys as the spec's verifiers take them: {key_id: {obi, public_key, valid_from_seq, valid_until_seq}}.
function directoryKeys(members) {
  const keys = {};
  for (const m of members) for (const k of m.keys) keys[k.key_id] = { obi: m.obi, public_key: k.public_key, valid_from_seq: k.valid_from_seq, valid_until_seq: k.valid_until_seq };
  return keys;
}

async function members(ctx) {
  return expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/members`), 200, "the members").members;
}

async function exchange(ctx, which, id) {
  return expect(await obid(ctx, which, `/obid/sphere/exchanges/${id}`), 200, `${which}'s exchange ${id}`);
}

// The obiRequest items of an obid's inbox, open and done.
async function obiRequestItems(ctx, which) {
  const open = expect(await obid(ctx, which, "/inbox"), 200, `${which}'s inbox`);
  const done = expect(await obid(ctx, which, "/inbox?state=done&limit=1000"), 200, `${which}'s settled inbox`);
  return [...open, ...done].filter((i) => i.kind === "obiRequest");
}

// The top-level names of a folder, as a set.
const topNames = (dir) => new Set(existsSync(dir) ? readdirSync(dir) : []);

// A job's worktree is inside obid A's home/worktrees/.
function insideWorktrees(ctx, path) {
  const root = join(ctx.obids.a.home, "worktrees") + sep;
  return typeof path === "string" && resolve(path).startsWith(root) && resolve(path).length > root.length;
}

// SCENARIO.md step 5.2: the worktree is at head_sha, with nothing changed outside .obi/.
function worktreeUntouched(path, what) {
  const head = git(path, ["rev-parse", "HEAD"]);
  assert(head === FIXTURE.headSha, `${what}'s worktree is at ${head}, not ${FIXTURE.headSha}`);
  const dirty = git(path, ["status", "--porcelain", "--untracked-files=all"]).split("\n").filter((l) => l && !l.includes(".obi/"));
  assert(dirty.length === 0, `${what}'s worktree changed outside .obi/: ${dirty.join(", ")}`);
}

// What the result of a review must be: exact in stub mode; in live mode, what SCENARIO.md's
// "Live mode" says (the model decides the findings).
function checkResult(ctx, body, byRule, what) {
  const want = byRule ? { ...EXPECTED_RESULT, by_rule: byRule } : EXPECTED_RESULT;
  if (!ctx.live) {
    assert(same(body, want), `${what}: the result body differs from SCENARIO.md's: ${show(body)}`);
    return;
  }
  assert(ctx.spec.schemaErrors("actions/result", body).length === 0, `${what}: the result doesn't match the spec's schema`);
  assert(ctx.spec.resultProblems(body).length === 0, `${what}: the result isn't consistent: ${ctx.spec.resultProblems(body).join("; ")}`);
  assert(body.acceptance?.[0]?.kind === "tests_pass" && body.acceptance[0].met === true, `${what}: tests_pass isn't met`);
  for (const [file, line] of [["src/average.js", 4], ["src/greet.js", 2]]) {
    const f = body.findings.find((x) => x.file === file && x.line === line);
    assert(f, `${what}: no finding at ${file} line ${line}`);
    assert(f.id === ctx.spec.findingId(f.file, f.line, f.title), `${what}: finding ${f.id} isn't the spec's derivation`);
  }
  const blocker = body.findings.some((f) => f.severity === "blocker");
  assert(body.outcome === (blocker ? "changes_requested" : "approved"), `${what}: outcome ${body.outcome} with ${blocker ? "a" : "no"} blocker`);
  assert((body.by_rule ?? null) === (byRule ?? null), `${what}: by_rule is ${body.by_rule}, not ${byRule}`);
}

// ---------------------------------------------------------------------------------------------

async function step1(ctx) {
  const R = ctx.runDir;
  // What step 8.4 compares with: the checkouts, the fixture, the remote's refs, the names at the
  // top of HOME and the system's temp, before anything starts.
  ctx.before = {
    obi: snapshot(OBI_DIR, SNAPSHOT_EXCLUDES.obi),
    obiSphere: snapshot(ctx.env.OBI_SPHERE_DIR, SNAPSHOT_EXCLUDES.obiSphere),
    fixture: snapshot(join(R, "fixture"), SNAPSHOT_EXCLUDES.fixture),
    refs: refs(ctx.fixture.remote),
    home: topNames(homedir()),
    tmp: topNames(tmpdir()),
  };
  // Remote mode (SCENARIO.md, "Against a deployed Sphere"): OBI_SPHERE_URL and SPHERE_OPERATOR_TOKEN
  // name a Sphere that is already running; this run makes a Sphere of its own id in it and starts no process.
  const remote = process.env.OBI_SPHERE_URL;
  const [portA, portB] = [await freePort(), await freePort()];
  if (remote) {
    assert(process.env.SPHERE_OPERATOR_TOKEN, "OBI_SPHERE_URL is set but SPHERE_OPERATOR_TOKEN isn't");
    ctx.sphereUrl = remote.replace(/\/+$/, "");
    ctx.operatorToken = process.env.SPHERE_OPERATOR_TOKEN;
    ctx.sphereId = `${SPHERE.id}-${randomBytes(4).toString("hex")}`;
  } else {
    ctx.sphereUrl = `http://127.0.0.1:${await freePort()}`;
    ctx.operatorToken = randomBytes(32).toString("base64url");
    ctx.sphereId = SPHERE.id;
  }
  ctx.owners = {
    w: { id: OBIS.a.owner, key: newKey(ctx.spec) },
    e: { id: OBIS.b.owner, key: newKey(ctx.spec) },
  };
  ctx.obids = {
    a: { ...OBIS.a, port: portA, token: randomBytes(32).toString("hex"), dir: join(R, "obid-a"), owner: ctx.owners.w },
    b: { ...OBIS.b, port: portB, token: randomBytes(32).toString("hex"), dir: join(R, "obid-b"), owner: ctx.owners.e },
  };
  for (const o of Object.values(ctx.obids)) o.home = join(o.dir, "home");

  // 1.1 The Sphere, with exactly the environment SCENARIO.md gives it.
  const sphereDir = join(R, "sphere");
  mkdirSync(join(R, "harness"), { recursive: true });
  if (!remote) for (const d of ["state", "home", "tmp"]) mkdirSync(join(sphereDir, d), { recursive: true });
  if (!remote) ctx.sphereProcess = ctx.start("sphere", process.execPath, ["scripts/local.mjs", "--port", new URL(ctx.sphereUrl).port, "--persist-to", join(sphereDir, "state")], {
    cwd: join(ctx.env.OBI_SPHERE_DIR, "server"),
    env: { SPHERE_OPERATOR_TOKEN: ctx.operatorToken, HOME: join(sphereDir, "home"), TMPDIR: join(sphereDir, "tmp"), WRANGLER_SEND_METRICS: "false", PATH: process.env.PATH },
    log: join(R, "harness", "sphere.log"),
  });
  await within(60, async () => {
    if (ctx.sphereProcess && (ctx.sphereProcess.exitCode !== null || ctx.sphereProcess.spawnError)) throw new Error(`the Sphere exited (${ctx.sphereProcess.spawnError?.message ?? ctx.sphereProcess.exitCode}); see R/harness/sphere.log`);
    const r = await sphere(ctx, "/health", { timeoutMs: 2000 });
    return r.status === 200 && same(r.body, { ok: true, protocol: "obi/0.1" }) ? r : undefined;
  }, (_, e) => `GET /v0.1/health didn't answer 200 {"ok": true, "protocol": "obi/0.1"}${e ? ` (${e.message})` : ""}`);

  // 1.2 The Sphere "e2e", wellington its admin.
  const created = expect(await sphere(ctx, "/spheres", {
    method: "POST",
    token: ctx.operatorToken,
    body: { sphere: ctx.sphereId, name: SPHERE.name, admin: { owner: OBIS.a.owner, owner_key: ctx.owners.w.key.publicKey } },
  }), 201, "POST /v0.1/spheres");
  assert(created.sphere === ctx.sphereId && created.admin_owner === OBIS.a.owner && created.protocol === "obi/0.1", `the Sphere answered ${show(created)}`);

  // 1.3 The admin token, as every later one is made.
  const token = expect(await sphere(ctx, "/oauth/token", {
    method: "POST",
    form: { grant_type: TOKEN_EXCHANGE, subject_token: assertion(ctx, ctx.owners.w, ADMIN_SCOPES), subject_token_type: JWT_TYPE },
  }), 200, "the admin token exchange");
  assert(token.token_type === "Bearer", `token_type is ${token.token_type}`);
  assert(token.scope === ADMIN_SCOPES, `the admin token's scope is "${token.scope}", not "${ADMIN_SCOPES}"`);

  // 1.4 One invitation per Obi.
  for (const o of Object.values(ctx.obids)) {
    const inv = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/invitations`, {
      method: "POST",
      body: { owner: o.owner.id, obi: o.id, expires_in: 3600 },
    }), 201, `the invitation for ${o.id}`);
    assert(typeof inv.invitation_id === "string" && inv.invitation_id, `the invitation for ${o.id} has no invitation_id`);
    assert(typeof inv.secret === "string" && inv.secret.length === 43, `the invitation for ${o.id} has no 43-character secret`);
    o.invitation = { id: inv.invitation_id, secret: inv.secret };
  }

  // 1.5 The policy.
  const policy = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/policy`), 200, "GET policy");
  assert(policy.version === 0 && same(policy.rules, []), `the new Sphere's policy is ${show(policy)}`);
  const written = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/policy`, { method: "PUT", body: { expected_version: 0, rules: POLICY_RULES } }), 200, "PUT policy");
  assert(written.version === 1 && same(written.rules, POLICY_RULES), `PUT policy answered ${show(written)}`);

  // 1.6 An empty audit chain.
  const audit = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/audit`), 200, "GET audit");
  assert(same(audit.entries, []) && audit.head?.seq === 0 && audit.head?.hash === ZERO_HASH, `the new Sphere's audit is ${show(audit)}`);
}

async function step2(ctx) {
  // 2.1 and 2.2: each obid's configuration, and obid started with exactly its environment.
  for (const [which, o] of Object.entries(ctx.obids)) {
    const live = ctx.live && which === "a";
    for (const d of ["env-home", "tmp"]) mkdirSync(join(o.dir, d), { recursive: true });
    const config = {
      listen: `127.0.0.1:${o.port}`,
      home: o.home,
      owner: o.owner.id,
      agents: {
        claude: live
          ? { bin: "claude", accounts: [{ id: "default", name: "Default", configDir: null }] }
          : { bin: ctx.env.STUB_AGENT, accounts: [{ id: "stub", name: "Stub", configDir: join(o.home, "accounts", "stub") }] },
      },
      repos: [{ repo: FIXTURE.repo, remote: ctx.fixture.remoteUrl, defaultBranch: FIXTURE.baseBranch, check: FIXTURE.check }],
      allowFileRemotes: true,
      telemetry: false,
    };
    o.config = join(o.dir, "config.json");
    writeFileSync(o.config, JSON.stringify(config, null, 2));
    // obid's token goes in home/api-token (0600) before it starts, never in its environment, where
    // other processes of the same user could read it (docs/runner-api.md, "obid only: configuration").
    mkdirSync(o.home, { recursive: true, mode: 0o700 });
    writeFileSync(join(o.home, "api-token"), `${o.token}\n`, { mode: 0o600, flag: "wx" });
    o.process = ctx.start(`obid-${which}`, ctx.env.OBID_BIN, ["serve", "--config", o.config], {
      env: {
        // Live mode: Claude Code's login lives in the person's real HOME.
        HOME: live ? homedir() : join(o.dir, "env-home"),
        TMPDIR: join(o.dir, "tmp"),
        PATH: process.env.PATH,
      },
      log: join(o.dir, "obid.log"),
    });
  }
  for (const [which, o] of Object.entries(ctx.obids)) {
    await within(30, async () => {
      if (o.process.exitCode !== null || o.process.spawnError) throw new Error(`obid ${which} exited (${o.process.spawnError?.message ?? o.process.exitCode}); see R/obid-${which}/obid.log`);
      const r = await obid(ctx, which, "/status", { timeoutMs: 2000 });
      return r.status === 200 && r.body?.runner?.engine === "obid" ? r : undefined;
    }, (_, e) => `obid ${which}'s GET /v1/status didn't answer 200 with runner.engine obid${e ? ` (${e.message})` : ""}`);
  }

  // 2.3 Each Obi's key, card, the owner's signatures, and the join.
  for (const [which, o] of Object.entries(ctx.obids)) {
    const key = expect(await obid(ctx, which, "/obid/sphere/key", { method: "POST" }), 200, `${which}: POST /v1/obid/sphere/key`);
    assert(typeof key.keyId === "string" && typeof key.publicKey === "string", `${which}: the key answer is ${show(key)}`);
    o.keyId = key.keyId;
    o.publicKey = key.publicKey;
    const made = expect(await obid(ctx, which, "/obid/sphere/card", {
      method: "POST",
      body: { url: ctx.sphereUrl, sphere: ctx.sphereId, obiId: o.id, name: o.name, ownerKey: o.owner.key.publicKey, accepts: o.accepts },
    }), 200, `${which}: POST /v1/obid/sphere/card`);
    const params = made.card?.capabilities?.extensions?.[0]?.params;
    assert(params?.key_id === o.keyId && params?.public_key === o.publicKey, `${which}: the card's Obi extension doesn't carry obid's keyId and publicKey`);
    assert(made.card.signatures === undefined, `${which}: the card came signed`);
    const card = ctx.spec.signCard(made.card, o.owner.key.privateKey, o.owner.key.keyId);
    const delegation = assertion(ctx, o.owner, OBI_SCOPES, { lifetime: 3600, mayAct: o.id });
    const joined = expect(await obid(ctx, which, "/obid/sphere/join", {
      method: "POST",
      body: { url: ctx.sphereUrl, sphere: ctx.sphereId, invitation: o.invitation, card, delegation },
    }), 200, `${which}: POST /v1/obid/sphere/join`);
    assert(joined.state === "joined" && joined.obiId === o.id && joined.keyId === o.keyId, `${which}: the membership is ${show(joined)}`);
  }

  // 2.4 The directory.
  const list = await members(ctx);
  assert(list.length === 2, `the directory has ${list.length} members, not 2`);
  for (const o of Object.values(ctx.obids)) {
    const m = list.find((x) => x.obi === o.id);
    assert(m, `${o.id} isn't in the directory`);
    assert(m.owner === o.owner.id && m.status === "active", `${o.id} is ${m.status}, owner ${m.owner}`);
    assert(m.keys.length === 1 && m.keys[0].key_id === o.keyId && m.keys[0].valid_from_seq === 1 && m.keys[0].valid_until_seq === null, `${o.id}'s keys are ${show(m.keys)}`);
    const verdict = ctx.spec.verifyCard(m.card, { now: timestamp(nowSeconds()), bound_owner_key: o.owner.key.publicKey });
    assert(verdict.ok, `${o.id}'s card fails the spec's check: ${verdict.code}: ${verdict.message}`);
  }
}

// POST /v1/obid/sphere/requests on B with the brief: the new exchange.
async function sendBrief(ctx) {
  const sent = expect(await obid(ctx, "b", "/obid/sphere/requests", {
    method: "POST",
    body: { to: OBIS.a.id, type: "review_request", body: BRIEF, expiresIn: EXPIRES_IN },
  }), 202, "B: POST /v1/obid/sphere/requests");
  assert(typeof sent.correlationId === "string", `B's exchange is ${show(sent)}`);
  assert(sent.direction === "outgoing" && sent.peer === OBIS.a.id && sent.state === "sent", `B's exchange is ${sent.direction}, ${sent.peer}, ${sent.state}`);
  return sent;
}

async function step3(ctx) {
  // 3.1
  const x = await sendBrief(ctx);
  assert(x.messages.length === 1, `B's exchange has ${x.messages.length} messages, not 1`);
  const [message] = x.messages;
  assert(message.seq === 1 && typeof message.envelope?.signature === "string", `B's message is ${show(message)}`);
  ctx.X = x.correlationId;
  ctx.requestX = message.envelope;

  // 3.2
  const audit = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/audit`), 200, "GET audit");
  assert(audit.entries.length === 1 && audit.entries[0].seq === 1, `the audit has ${audit.entries.length} entries`);
  const env = audit.entries[0].envelope;
  assert(same(env, message.envelope), "the audit's envelope differs from B's message");
  assert(env.type === "review_request" && env.from === OBIS.b.id && env.to === OBIS.a.id, `the entry is a ${env.type} from ${env.from} to ${env.to}`);
  assert(env.id === ctx.X && env.correlation_id === ctx.X, "the entry's id and correlation_id aren't X");
  assert(env.key_id === ctx.obids.b.keyId, "the entry isn't signed with B's key");
  assert(same(env.body, BRIEF), "the entry's body differs from the brief");
  const keys = directoryKeys(await members(ctx));
  const verdict = ctx.spec.verifyEnvelope(env, { now: timestamp(nowSeconds()), sphere: ctx.sphereId, receiver: OBIS.a.id, keys, seq: 1, seen_ids: [] });
  assert(verdict.ok, `verifyEnvelope refuses it: ${verdict.code}: ${verdict.message}`);
}

async function step4(ctx) {
  // 4.1
  const none = expect(await obid(ctx, "a", "/obid/decisions"), 200, "A: GET /v1/obid/decisions");
  assert(same(none, []), `A has decisions already: ${show(none)}`);

  // 4.2
  const item = await within(30, async () => {
    const items = expect(await obid(ctx, "a", "/inbox"), 200, "A: GET /v1/inbox").filter((i) => i.kind === "obiRequest");
    if (items.length === 0) return undefined;
    assert(items.length === 1, `A's inbox has ${items.length} obiRequest items`);
    return items[0];
  }, (_, e) => (e ? e.message : "A's inbox has no obiRequest item"));
  assert(item.obi?.correlationId === ctx.X, `the item is for ${item.obi?.correlationId}, not X`);
  assert(same(item.options, INBOX_OPTIONS), `the item's options are ${show(item.options)}`);
  assert(!item.title.includes(CANARY) && !item.text.includes(CANARY), "the item's title or text carries the request's data text");
  assert(item.obi.quoted?.goal === BRIEF.goal, "obi.quoted.goal isn't the brief's goal");
  const x = await exchange(ctx, "a", ctx.X);
  assert(x.direction === "incoming" && x.state === "inbox" && x.inboxItem === item.id, `A's exchange X is ${x.direction}, ${x.state}, inboxItem ${x.inboxItem}`);
  ctx.inboxItem = item.id;

  // 4.3
  const answered = expect(await obid(ctx, "a", `/inbox/${encodeURIComponent(item.id)}/answer`, { method: "POST", body: { answer: INBOX_ANSWER } }), 200, "A: POST /v1/inbox/{id}/answer");
  assert(answered.state === "done" && answered.answer === INBOX_ANSWER, `the answered item is ${answered.state}, answer ${answered.answer}`);

  // 4.4
  const decisions = expect(await obid(ctx, "a", "/obid/decisions"), 200, "A: GET /v1/obid/decisions");
  assert(decisions.length === 1, `A has ${decisions.length} decisions, not 1`);
  const [d] = decisions;
  const { type, fromOwner, repo, decision } = d;
  assert(same({ type, fromOwner, repo, decision }, EXPECTED_DECISION), `the decision is ${show(d)}`);
  assert(/^d-[0-9a-f]{12}$/.test(d.id), `the decision's id is ${d.id}`);
  ctx.D1 = d.id;

  // 4.5
  const accepted = await within(10, async () => {
    const e = await exchange(ctx, "a", ctx.X);
    return ["accepted", "done"].includes(e.state) && e.job ? e : undefined;
  }, () => "A's exchange X isn't accepted with a job");
  assert(accepted.decidedBy === "inbox" && accepted.rule === null, `A's exchange X: decidedBy ${accepted.decidedBy}, rule ${accepted.rule}`);
  ctx.J1 = accepted.job;
  // The worktree is null until obid has made it: within the same 10 seconds.
  const job = await within(10, async () => {
    const j = expect(await obid(ctx, "a", `/jobs/${ctx.J1}`), 200, "A: GET /v1/jobs/J1");
    return j.worktree ? j : undefined;
  }, () => "job J1 has no worktree");
  assert(job.kind === "review" && job.repo === FIXTURE.repo, `J1 is a ${job.kind} job on ${job.repo}`);
  assert(job.obi?.correlationId === ctx.X && job.obi?.fromOwner === OBIS.b.owner, `J1's obi is ${show(job.obi)}`);
  assert(insideWorktrees(ctx, job.worktree), `J1's worktree ${job.worktree} isn't inside R/obid-a/home/worktrees/`);
  ctx.worktreeJ1 = job.worktree;
}

// GET /v1/jobs/{id}/wait on A: the job once it has ended.
async function waitJob(ctx, id, seconds) {
  let r;
  try {
    r = await obid(ctx, "a", `/jobs/${id}/wait`, { timeoutMs: seconds * 1000 });
  } catch (e) {
    throw new Error(`job ${id} didn't end within ${seconds} seconds (${e.message})`);
  }
  return expect(r, 200, `A: GET /v1/jobs/${id}/wait`);
}

// B's exchange as SCENARIO.md step 5.4 wants it: the request, an accept (`acceptBody`), any
// statuses, a result; every received envelope passing the spec's check.
async function checkOutgoing(ctx, id, acceptBody, byRule, seconds, what) {
  const e = await within(seconds, async () => {
    const got = await exchange(ctx, "b", id);
    return got.state === "done" ? got : undefined;
  }, () => `B's exchange ${what} isn't done`);
  const types = e.messages.map((m) => `${m.direction} ${m.envelope.type}`);
  assert(types.length >= 3 && types[0] === "sent review_request" && types[1] === "received accept" && types.at(-1) === "received result"
    && types.slice(2, -1).every((t) => t === "received status"), `B's exchange ${what} has ${types.join(", ")}`);
  assert(same(e.messages[1].envelope.body, acceptBody), `the accept's body is ${show(e.messages[1].envelope.body)}, not ${show(acceptBody)}`);
  checkResult(ctx, e.messages.at(-1).envelope.body, byRule, `${what}'s result`);
  const keys = directoryKeys(await members(ctx));
  for (const m of e.messages.filter((x) => x.direction === "received")) {
    const verdict = ctx.spec.verifyEnvelope(m.envelope, { now: timestamp(nowSeconds()), sphere: ctx.sphereId, receiver: OBIS.b.id, keys, seq: m.seq, seen_ids: [] });
    assert(verdict.ok, `B's received ${m.envelope.type} fails verifyEnvelope: ${verdict.code}: ${verdict.message}`);
  }
  return e;
}

async function step5(ctx) {
  // 5.1
  const job = await waitJob(ctx, ctx.J1, 120);
  assert(job.status === "done", `J1 ended ${job.status}: ${job.summary}`);
  assert(job.publishError === null && job.published === null && same(job.outgoing, []), `J1 published something: publishError ${job.publishError}, published ${show(job.published)}, outgoing ${show(job.outgoing)}`);
  // 5.2
  worktreeUntouched(ctx.worktreeJ1, "J1");
  // 5.3
  const x = await exchange(ctx, "a", ctx.X);
  assert(x.state === "done" && same(x.publishScan, { ran: true, clean: true }), `A's exchange X is ${x.state}, publishScan ${show(x.publishScan)}${x.error ? `: ${x.error}` : ""}`);
  // 5.4
  ctx.outgoingX = await checkOutgoing(ctx, ctx.X, {}, undefined, 30, "X");
}

async function step6(ctx) {
  // 6.1
  const y = await sendBrief(ctx);
  ctx.Y = y.correlationId;
  // 6.2
  ctx.outgoingY = await checkOutgoing(ctx, ctx.Y, { by_rule: ctx.D1 }, ctx.D1, 120, "Y");
  // 6.3
  const a = await exchange(ctx, "a", ctx.Y);
  assert(a.decidedBy === "rule" && a.rule === ctx.D1 && a.inboxItem === null, `A's exchange Y: decidedBy ${a.decidedBy}, rule ${a.rule}, inboxItem ${a.inboxItem}`);
  assert(a.job && a.job !== ctx.J1, `A's exchange Y's job is ${a.job}`);
  ctx.J2 = a.job;
  const job = await waitJob(ctx, ctx.J2, 120);
  assert(insideWorktrees(ctx, job.worktree) && job.worktree !== ctx.worktreeJ1, `J2's worktree ${job.worktree} isn't a fresh one inside R/obid-a/home/worktrees/`);
  ctx.worktreeJ2 = job.worktree;
  // 6.4
  const items = await obiRequestItems(ctx, "a");
  assert(items.length === 1 && items[0].id === ctx.inboxItem, `A's inbox has ${items.length} obiRequest items: ${items.map((i) => i.id).join(", ")}`);
  const decisions = expect(await obid(ctx, "a", "/obid/decisions"), 200, "A: GET /v1/obid/decisions");
  assert(decisions.length === 1 && decisions[0].id === ctx.D1 && decisions[0].uses === 1, `A's decisions are ${show(decisions)}`);
}

async function step7(ctx) {
  // 7.1
  const audit = expect(await asAdmin(ctx, `/spheres/${ctx.sphereId}/audit?from_seq=1&limit=1000`), 200, "GET audit");
  const list = await members(ctx);
  // 7.2
  const verdict = ctx.spec.verifyChain({ sphere: ctx.sphereId, entries: audit.entries }, { keys: directoryKeys(list) });
  assert(verdict.ok, `verifyChain refuses the chain: ${verdict.code}: ${verdict.message}`);
  // 7.3 Exactly the two exchanges, each envelope as its sender keeps it.
  const a = { X: await exchange(ctx, "a", ctx.X), Y: await exchange(ctx, "a", ctx.Y) };
  const b = { X: ctx.outgoingX, Y: await exchange(ctx, "b", ctx.Y) };
  const sentBy = (e) => e.messages.filter((m) => m.direction === "sent").map((m) => m.envelope);
  let at = 0;
  const entries = audit.entries;
  for (const name of ["X", "Y"]) {
    const id = ctx[name];
    const next = () => entries[at++]?.envelope;
    const request = next();
    assert(request?.type === "review_request" && request.from === OBIS.b.id && request.key_id === ctx.obids.b.keyId && request.id === id, `entry ${at} isn't ${name}'s review_request from ${OBIS.b.id}`);
    assert(sentBy(b[name]).some((env) => same(env, request)), `entry ${at} differs from the request in B's exchange ${name}`);
    const replies = [];
    while (entries[at] && entries[at].envelope.correlation_id === id) replies.push(next());
    const kinds = replies.map((r) => r.type);
    assert(kinds.length >= 2 && kinds[0] === "accept" && kinds.at(-1) === "result" && kinds.slice(1, -1).every((k) => k === "status"), `${name}'s replies in the chain are ${kinds.join(", ")}`);
    for (const r of replies) {
      assert(r.from === OBIS.a.id && r.key_id === ctx.obids.a.keyId, `a ${r.type} in ${name} isn't from ${OBIS.a.id} with A's key`);
      assert(sentBy(a[name]).some((env) => same(env, r)), `the ${r.type} in the chain differs from the one in A's exchange ${name}`);
    }
  }
  assert(at === entries.length, `the chain has ${entries.length - at} entries besides the two exchanges`);
  assert(audit.head.seq === entries.length && audit.head.hash === entries.at(-1).hash, `the head is ${show(audit.head)}`);
  ctx.chainVerified = true;
}

// Test the documented PID-only shutdown. Failure cleanup in run.mjs still
// signals groups so a broken launcher cannot leave a Worker behind.
async function stop(child, seconds) {
  const deadline = Date.now() + seconds * 1000;
  child.kill("SIGTERM");
  const exited = await Promise.race([child.exited, sleep(seconds * 1000).then(() => null)]);
  if (!exited) return null;
  // The launcher exiting isn't enough: its children must also have stopped.
  while (Date.now() < deadline) {
    if (!groupRunning(child.pid)) return exited;
    await sleep(100);
  }
  return null;
}

async function step8(ctx) {
  // 8.1 Findings: both results carried the two known findings.
  for (const [name, e] of [["X", ctx.outgoingX], ["Y", ctx.outgoingY]]) {
    const ids = e.result.findings.map((f) => f.id);
    if (!ctx.live) assert(same(ids, EXPECTED_FINDINGS.map((f) => f.id)), `${name}'s result has findings ${ids.join(", ")}`);
  }
  if (ctx.live) {
    const ids = (e) => e.result.findings.map((f) => f.id).sort();
    assert(same(ids(ctx.outgoingX), ids(ctx.outgoingY)), "the two results' findings differ by id");
  }
  // 8.2 The inbox was used exactly once.
  const itemsA = await obiRequestItems(ctx, "a");
  assert(itemsA.length === 1, `A has ${itemsA.length} obiRequest items in all`);
  const itemsB = await obiRequestItems(ctx, "b");
  assert(itemsB.length === 0, `B has ${itemsB.length} obiRequest items`);
  // 8.3 The audit chain verifies.
  assert(ctx.chainVerified, "the chain wasn't verified (step 7)");
  // 8.5 Nothing was pushed.
  const after = refs(ctx.fixture.remote);
  const want = `refs/heads/${FIXTURE.headBranch} ${FIXTURE.headSha}\nrefs/heads/${FIXTURE.baseBranch} ${FIXTURE.baseSha}`;
  assert(after === ctx.before.refs && after === want, `the remote's refs are now:\n${after}`);
  // 8.6 Clean exit: SIGTERM to obid A, obid B and the Sphere.
  for (const [name, child, zero] of [["obid A", ctx.obids.a.process, true], ["obid B", ctx.obids.b.process, true], ["the Sphere", ctx.sphereProcess, false]].filter(([, child]) => child)) {
    const exit = await stop(child, 10);
    assert(exit, `${name} or its descendants were still running 10 seconds after PID-only SIGTERM`);
    if (zero) assert(exit.code === 0, `${name} exited with ${exit.code ?? exit.signal}, not 0`);
  }
  // 8.4 No process wrote outside its write root, as far as the run can see.
  const R = ctx.runDir;
  for (const [name, root, key] of [["the obi checkout", OBI_DIR, "obi"], ["the obi-sphere checkout", ctx.env.OBI_SPHERE_DIR, "obiSphere"], ["R/fixture", join(R, "fixture"), "fixture"]]) {
    const changed = changes(ctx.before[key], snapshot(root, SNAPSHOT_EXCLUDES[key]));
    assert(changed.length === 0, `something wrote in ${name}: ${changed.slice(0, 10).join(", ")}${changed.length > 10 ? ` and ${changed.length - 10} more` : ""}`);
  }
  const worktreesB = join(ctx.obids.b.home, "worktrees");
  assert(!existsSync(worktreesB) || readdirSync(worktreesB).length === 0, `obid B has worktrees: ${existsSync(worktreesB) ? readdirSync(worktreesB).join(", ") : ""}`);
  worktreeUntouched(ctx.worktreeJ1, "J1");
  worktreeUntouched(ctx.worktreeJ2, "J2");
  const runName = basename(R);
  const appeared = (before, dir) => [...topNames(dir)].filter((n) => !before.has(n) && WATCHED_NAME.test(n) && !(dir === dirname(R) && n === runName));
  // Live mode: obid A keeps the person's real HOME, where Claude Code writes by design.
  const inHome = ctx.live ? [] : appeared(ctx.before.home, homedir());
  const inTmp = appeared(ctx.before.tmp, tmpdir());
  assert(inHome.length === 0, `new in HOME: ${inHome.join(", ")}`);
  assert(inTmp.length === 0, `new in the system's temp folder: ${inTmp.join(", ")}`);
}

const STEPS = { 1: step1, 2: step2, 3: step3, 4: step4, 5: step5, 6: step6, 7: step7, 8: step8 };

// Runs step `n` with the harness's `ctx`.
export function runStep(n, ctx) {
  return STEPS[n](ctx);
}
