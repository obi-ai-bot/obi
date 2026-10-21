#!/usr/bin/env node
// A job that runs on a teammate's Mac, end to end on one Mac (#797; docs/research/sphere-sharing.md):
// a Sphere (local, from OBI_SPHERE_DIR), Wellington's obid sharing this Mac and Sangam's obid sending
// a job to it, each in a home of its own. The job runs in a real VM (core/obi-vm and its image), with
// the real Claude Code inside; its model calls go back through the job channel to Sangam's obid,
// which calls the model's API from there with Sangam's own Claude Code login: the login never
// leaves Sangam's side (the owner's decision of 2026-10-21). The login and the model's API are
// stand-ins: no real login or key is used.
//
//   node e2e/sharing.mjs --image <dir with vmlinuz, initrd, root.img>
//
// Environment:
//   OBI_SPHERE_DIR   the obi-sphere checkout with the job channel (default: ../obi-sphere)
//   OBID_BIN         obid (default: core/target/debug/obid)
//   OBI_VM_BIN       obi-vm (default: core/obi-vm/build/obi-vm)
//   A stand-in model API on this Mac answers (one Bash call, then "Done"), and Sangam's Claude Code
//   login is a stand-in one in Sangam's account folder.
//   OBI_E2E_KEEP=1   keep the run folder.
//
// This Mac's own signals (idle time, power) decide whether a guest job may run, and the person
// running this is at it: so obi-vm's `signals` is read from a file this script writes (the Mac
// away, on power), through a small wrapper; every other obi-vm command is the real one. Midway the
// script says the owner came back, checks the VM paused, and says they left again.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { buildFixture } from "./lib/fixture.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const OBI = resolve(here, "..");
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? undefined : process.argv[i + 1];
};
const IMAGE = resolve(arg("--image") ?? join(OBI, "core/obi-vm/image/out"));
const SPHERE_DIR = resolve(process.env.OBI_SPHERE_DIR ?? join(OBI, "..", "obi-sphere"));
const OBID = resolve(process.env.OBID_BIN ?? join(OBI, "core/target/debug/obid"));
const OBI_VM = resolve(process.env.OBI_VM_BIN ?? join(OBI, "core/obi-vm/build/obi-vm"));
const R = mkdtempSync(join(tmpdir(), "obi-sharing-"));
const spec = await import(pathToFileURL(join(SPHERE_DIR, "spec/conformance/lib/obi.mjs")).href);

const children = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Math.floor(Date.now() / 1000);
const step = (text) => console.log(`\n== ${text}`);
const pass = (text) => console.log(`  PASS  ${text}`);
const fail = (text) => {
  throw new Error(text);
};
const freePort = () =>
  new Promise((ok) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => ok(port));
    });
  });
const within = async (seconds, what, probe, every = 500) => {
  const end = Date.now() + seconds * 1000;
  for (;;) {
    const got = await probe().catch(() => undefined);
    if (got) return got;
    if (Date.now() > end) fail(`within ${seconds} s: ${what}`);
    await sleep(every);
  }
};
const start = (name, cmd, args, opts) => {
  const child = spawn(cmd, args, { ...opts, stdio: ["ignore", "pipe", "pipe"], detached: true });
  const log = join(R, `${name}.log`);
  child.stdout.on("data", (d) => writeFileSync(log, d, { flag: "a" }));
  child.stderr.on("data", (d) => writeFileSync(log, d, { flag: "a" }));
  children.push(child);
  return child;
};
async function call(url, { method = "GET", token, body, form } = {}) {
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
  const res = await fetch(url, { method, headers, body: payload });
  const text = await res.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {}
  return { status: res.status, body: parsed };
}
const expect = (r, status, what) => (r.status === status ? r.body : fail(`${what}: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`));

// ---------------------------------------------------------------------------------------------
// A stand-in for Anthropic's Messages API: one Bash tool call that writes guest.txt, then "Done".

function fakeModel(port) {
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const asked = JSON.parse(raw || "{}");
      const login = readFileSync(join(R, "login"), "utf8").trim();
      const whose = req.headers.authorization === `Bearer ${login}` && !req.headers["x-api-key"] && (req.headers["anthropic-beta"] ?? "").includes("oauth-2025-04-20") ? "the guest's login" : "other";
      writeFileSync(join(R, "model-calls.log"), `${req.method} ${req.url} with=${whose}\n`, { flag: "a" });
      const used = (asked.messages ?? []).some((m) => Array.isArray(m.content) && m.content.some((c) => c.type === "tool_result"));
      const ev = (t, o) => `event: ${t}\ndata: ${JSON.stringify(o)}\n\n`;
      const out = [ev("message_start", { type: "message_start", message: { id: "msg_e2e", type: "message", role: "assistant", model: asked.model ?? "fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 100, output_tokens: 1 } } })];
      if (used || !asked.tools?.length) {
        out.push(ev("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }));
        out.push(ev("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Done: wrote guest.txt." } }));
        out.push(ev("content_block_stop", { type: "content_block_stop", index: 0 }));
        out.push(ev("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 6 } }));
      } else {
        const input = JSON.stringify({ command: "echo 'hello from a VM on another Mac' > guest.txt", description: "Write guest.txt" });
        out.push(ev("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_e2e", name: "Bash", input: {} } }));
        out.push(ev("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: input } }));
        out.push(ev("content_block_stop", { type: "content_block_stop", index: 0 }));
        out.push(ev("message_delta", { type: "message_delta", delta: { stop_reason: "tool_use", stop_sequence: null }, usage: { output_tokens: 20 } }));
      }
      out.push(ev("message_stop", { type: "message_stop" }));
      res.writeHead(200, { "content-type": "text/event-stream" });
      for (const chunk of out) res.write(chunk);
      res.end();
    });
  });
  return new Promise((ok) => server.listen(port, "127.0.0.1", () => ok(server)));
}

// ---------------------------------------------------------------------------------------------

async function main() {
  console.log(`Obi e2e: a job on a teammate's Mac (run folder ${R})`);
  for (const [what, path] of [["obid", OBID], ["obi-vm", OBI_VM], ["the image", join(IMAGE, "root.img")], ["obi-sphere", join(SPHERE_DIR, "server/src/channel.ts")]]) {
    if (!existsSync(path)) fail(`${what} isn't at ${path}`);
  }

  step("1. The Sphere, its policy, and two invitations");
  const spherePort = await freePort();
  const sphereUrl = `http://127.0.0.1:${spherePort}`;
  const operator = randomBytes(32).toString("base64url");
  for (const d of ["state", "home", "tmp"]) mkdirSync(join(R, "sphere", d), { recursive: true });
  start("sphere", process.execPath, ["scripts/local.mjs", "--port", String(spherePort), "--persist-to", join(R, "sphere/state")], {
    cwd: join(SPHERE_DIR, "server"),
    env: { SPHERE_OPERATOR_TOKEN: operator, HOME: join(R, "sphere/home"), TMPDIR: join(R, "sphere/tmp"), WRANGLER_SEND_METRICS: "false", PATH: process.env.PATH },
  });
  await within(90, "the Sphere answering", async () => (await call(`${sphereUrl}/v0.1/health`)).status === 200);
  const owner = (id) => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const pub = publicKey.export({ format: "jwk" }).x;
    return { id, privateKey, publicKey: pub, keyId: spec.keyIdOf(pub) };
  };
  const W = owner("wellington");
  const S = owner("sangam");
  const SPHERE = "deskree-e2e";
  const jwt = (o, scope, mayAct, lifetime = 300) => {
    const iat = now();
    const claims = { iss: o.id, sub: o.id, aud: `obi-sphere:${SPHERE}`, iat, exp: iat + lifetime, jti: randomUUID(), scope };
    if (mayAct) claims.may_act = { sub: mayAct };
    return spec.signJwt(claims, o.privateKey, o.keyId);
  };
  expect(await call(`${sphereUrl}/v0.1/spheres`, { method: "POST", token: operator, body: { sphere: SPHERE, name: "Deskree (e2e)", admin: { owner: "wellington", owner_key: W.publicKey } } }), 201, "the Sphere");
  const admin = async () =>
    expect(await call(`${sphereUrl}/v0.1/oauth/token`, { method: "POST", form: { grant_type: "urn:ietf:params:oauth:grant-type:token-exchange", subject_token: jwt(W, "admin directory:read audit:read"), subject_token_type: "urn:ietf:params:oauth:token-type:jwt" } }), 200, "the admin token").access_token;
  const invite = async (o, obi) => {
    const inv = expect(await call(`${sphereUrl}/v0.1/spheres/${SPHERE}/invitations`, { method: "POST", token: await admin(), body: { owner: o.id, obi, expires_in: 3600 } }), 201, `${obi}'s invitation`);
    return { id: inv.invitation_id, secret: inv.secret };
  };
  expect(await call(`${sphereUrl}/v0.1/spheres/${SPHERE}/policy`, { method: "PUT", token: await admin(), body: { expected_version: 0, rules: [{ id: "team", from_owner: "*", to_owner: "*", actions: ["review_request", "run_request"], repos: ["*"] }] } }), 200, "the policy");
  pass(`Sphere ${SPHERE} at ${sphereUrl}, the policy allows run_request`);

  step("2. Two obids: Wellington's shares this Mac, Sangam is signed in to Claude Code");
  const fixture = buildFixture(join(R, "fixture"));
  const modelPort = await freePort();
  // Sangam's Claude Code login: a stand-in, its access token and a refresh token that must never travel.
  const login = `e2e-claude-login-${randomBytes(16).toString("hex")}`;
  const refresh = `e2e-claude-refresh-${randomBytes(16).toString("hex")}`;
  writeFileSync(join(R, "login"), login, { mode: 0o600 });
  await fakeModel(modelPort);
  // obi-vm, except `signals`, which this run decides.
  const signals = join(R, "signals.json");
  const away = { idleSeconds: 900, onAC: true, lowPower: false, thermal: "nominal" };
  writeFileSync(signals, JSON.stringify(away));
  const wrapper = join(R, "obi-vm");
  writeFileSync(wrapper, `#!/bin/sh\nif [ "$1" = signals ]; then cat '${signals}'; exit 0; fi\nexec '${OBI_VM}' "$@"\n`);
  chmodSync(wrapper, 0o755);
  const obids = {};
  for (const [who, o, obi, accepts] of [["host", W, "obi-wellington", ["review_request", "run_request"]], ["guest", S, "obi-sangam", ["review_request"]]]) {
    const dir = join(R, who);
    const home = join(dir, "home");
    for (const d of ["env-home", "tmp"]) mkdirSync(join(dir, d), { recursive: true });
    mkdirSync(home, { recursive: true, mode: 0o700 });
    if (who === "guest") {
      mkdirSync(join(home, "accounts/stub"), { recursive: true, mode: 0o700 });
      writeFileSync(join(home, "accounts/stub/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: login, refreshToken: refresh, expiresAt: Date.now() + 86_400_000, scopes: ["user:inference"], subscriptionType: "max" } }), { mode: 0o600 });
    }
    const port = await freePort();
    const token = randomBytes(32).toString("hex");
    writeFileSync(join(home, "api-token"), `${token}\n`, { mode: 0o600 });
    const config = {
      listen: `127.0.0.1:${port}`, home, owner: o.id,
      agents: { claude: { bin: join(OBI, "e2e/stub-agent/stub-agent"), accounts: [{ id: "stub", name: "Stub", configDir: join(home, "accounts/stub") }] } },
      repos: [{ repo: "obi-e2e/fixture-app", remote: fixture.remoteUrl, defaultBranch: "main", check: "node --test" }],
      allowFileRemotes: true, telemetry: false,
      ...(who === "host" ? { vmHelper: wrapper, vmImage: IMAGE } : { guestModelApi: `http://127.0.0.1:${modelPort}` }),
    };
    writeFileSync(join(dir, "config.json"), JSON.stringify(config, null, 2));
    start(`obid-${who}`, OBID, ["serve", "--config", join(dir, "config.json")], { env: { HOME: join(dir, "env-home"), TMPDIR: join(dir, "tmp"), PATH: process.env.PATH } });
    const api = (path, opts = {}) => call(`http://127.0.0.1:${port}/v1${path}`, { ...opts, token });
    await within(30, `${who}'s obid answering`, async () => (await api("/status")).status === 200);
    const made = expect(await api("/obid/sphere/key", { method: "POST" }), 200, "the key");
    const card = expect(await api("/obid/sphere/card", { method: "POST", body: { url: sphereUrl, sphere: SPHERE, obiId: obi, name: `${o.id}'s Obi`, ownerKey: o.publicKey, accepts } }), 200, "the card").card;
    const joined = expect(await api("/obid/sphere/join", { method: "POST", body: { url: sphereUrl, sphere: SPHERE, invitation: await invite(o, obi), card: spec.signCard(card, o.privateKey, o.keyId), delegation: jwt(o, "send:review_request send:question send:run_request reply receive directory:read audit:read", obi, 3600) } }), 200, "the join");
    if (joined.state !== "joined" || !made.keyId) fail(`${who} didn't join`);
    obids[who] = { api, dir, home, obi };
  }
  const mac = expect(await obids.host.api("/obid/sharing/mac"), 200, "the host's sharing");
  if (mac.settings.on !== false) fail("sharing isn't off by default");
  const on = expect(await obids.host.api("/obid/sharing/mac", { method: "PUT", body: { ...mac.settings, on: true } }), 200, "sharing on");
  if (!on.ready) fail("the host says it can't run guests (obi-vm or the image)");
  pass(`both joined; sharing on with the defaults: ${JSON.stringify({ when: on.settings.when, who: on.settings.who, jobs: on.settings.jobsAtOnce, size: on.settings.size, minutes: on.settings.maxMinutes })}`);

  step("3. Sangam sends a job to Wellington's Mac");
  const macs = await within(60, "Wellington's Mac in Sangam's list", async () => {
    const list = expect(await obids.guest.api("/obid/sharing/macs"), 200, "the Macs");
    return list.find((m) => m.obi === "obi-wellington" && m.free) && list;
  });
  pass(`Sangam sees ${JSON.stringify(macs)}`);
  const job = expect(await obids.guest.api("/jobs", { method: "POST", body: { job: { repo: "obi-e2e/fixture-app", kind: "build", title: "Say hello from the VM", task: "Write guest.txt saying hello.", runsOn: "obi-wellington" } } }), 201, "the job");
  if (job.runsOn?.owner !== "wellington") fail(`the job's runsOn is ${JSON.stringify(job.runsOn)}`);
  const ask = await within(60, "the ask in Wellington's inbox", async () => (expect(await obids.host.api("/inbox"), 200, "the inbox")).find((i) => i.obi?.type === "run_request"));
  pass(`Wellington's inbox: "${ask.title}" [${ask.options.join(" | ")}]`);
  expect(await obids.host.api(`/inbox/${ask.id}/answer`, { method: "POST", body: { answer: "Allow sangam from now on" } }), 200, "Allow");

  step("4. It runs in a VM on this Mac; the owner comes back, and leaves again");
  await within(120, "the job running in the VM", async () => (expect(await obids.host.api("/obid/sharing/mac"), 200, "")).jobs.find((j) => j.state === "running"));
  const t0 = Date.now();
  writeFileSync(signals, JSON.stringify({ ...away, idleSeconds: 0 }));
  await within(10, "the VM paused", async () => (expect(await obids.host.api("/obid/sharing/mac"), 200, "")).jobs.find((j) => j.state === "paused"), 50);
  const pausedAfter = (Date.now() - t0) / 1000;
  if (pausedAfter > 1.5) fail(`it paused ${pausedAfter} s after the owner came back`);
  const vmPid = execFileSync("pgrep", ["-n", "-f", "com.apple.Virtualization.VirtualMachine"], { encoding: "utf8" }).trim();
  await sleep(2000);
  const cpu = execFileSync("ps", ["-o", "%cpu=", "-p", vmPid], { encoding: "utf8" }).trim();
  pass(`paused ${pausedAfter.toFixed(2)} s after the owner came back; the VM's process at ${cpu}% CPU 2 s later`);
  writeFileSync(signals, JSON.stringify({ ...away, idleSeconds: 130 }));
  await within(10, "the VM resumed", async () => (expect(await obids.host.api("/obid/sharing/mac"), 200, "")).jobs.find((j) => j.state === "running"));
  pass("resumed once the owner left it alone again");

  step("5. It comes back to Sangam, whose obid checks and publishes it");
  const done = await within(600, "the job done", async () => {
    const j = expect(await obids.guest.api(`/jobs/${job.id}`), 200, "the job");
    return ["done", "failed", "interrupted"].includes(j.status) && j;
  });
  if (done.status !== "done") fail(`the job ended ${done.status}: ${done.reason ?? done.summary}`);
  const shown = execFileSync("git", ["--git-dir", fixture.remote, "show", `${done.branch}:guest.txt`], { encoding: "utf8" }).trim();
  const author = execFileSync("git", ["--git-dir", fixture.remote, "log", "-1", "--format=%an", done.branch], { encoding: "utf8" }).trim();
  pass(`done with ${done.commits} commit, pushed: guest.txt says "${shown}", author ${author}`);

  step("6. What each side kept");
  const calls = existsSync(join(R, "model-calls.log")) ? readFileSync(join(R, "model-calls.log"), "utf8").trim().split("\n") : [];
  if (!calls.length || calls.some((c) => !c.includes("with=the guest's login"))) fail(`the model calls: ${calls.join("; ")}`);
  pass(`${calls.length} model calls, each from Sangam's obid with Sangam's own login (the VM's placeholder dropped)`);
  // grep exits 1 when it finds nothing: what this wants.
  for (const [what, secret] of [["login", login], ["refresh token", refresh]]) {
    const search = spawnSync("grep", ["-rl", "--binary-files=text", secret, obids.host.home, join(R, "host"), join(R, "sphere")], { encoding: "utf8" });
    if (search.status !== 1) fail(`Sangam's ${what} is on Wellington's side or the Sphere's: ${search.stdout}`);
  }
  pass("Sangam's login and refresh token are nowhere on Wellington's side or in the Sphere's state");
  const log = readFileSync(join(obids.host.home, "sharing-log.jsonl"), "utf8").trim();
  pass(`Wellington's sharing log: ${log}`);
  const audit = expect(await call(`${sphereUrl}/v0.1/spheres/${SPHERE}/audit`, { token: await admin() }), 200, "the audit chain");
  const verdict = spec.verifyChain({ sphere: SPHERE, entries: audit.entries }, { keys: Object.fromEntries((expect(await call(`${sphereUrl}/v0.1/spheres/${SPHERE}/members`, { token: await admin() }), 200, "members").members).flatMap((m) => m.keys.map((k) => [k.key_id, { obi: m.obi, public_key: k.public_key, valid_from_seq: k.valid_from_seq, valid_until_seq: k.valid_until_seq }]))) });
  if (!verdict.ok) fail(`the audit chain doesn't verify: ${verdict.message}`);
  pass(`the audit chain verifies: ${audit.entries.map((e) => e.envelope.type).join(", ")}`);
}

let ok = false;
try {
  await main();
  ok = true;
  console.log("\nAll steps passed.");
} catch (e) {
  console.log(`\nFAIL: ${e.message}\n(logs in ${R})`);
} finally {
  for (const c of children) {
    try {
      process.kill(-c.pid, "SIGTERM");
    } catch {}
  }
  await sleep(1000);
  if (ok && !process.env.OBI_E2E_KEEP) rmSync(R, { recursive: true, force: true });
}
process.exit(ok ? 0 : 1);
