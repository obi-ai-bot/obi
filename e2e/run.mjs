#!/usr/bin/env node
// The end-to-end harness: "a review across two Obis" (e2e/SCENARIO.md, which is what done means).
//
//   make e2e         stub agents, no model credentials, headless on Linux and macOS
//   make e2e-live    the real Claude Code adapter, run by a person on a Mac
//
// Environment:
//   OBI_SPHERE_DIR   the obi-sphere checkout (default: ../obi-sphere next to this repository)
//   OBID_BIN         the obid binary (default: core/target/debug/obid in this repository)
//   OBI_E2E_RUN_DIR  where the run keeps its files (default: a new folder under the system's temp)
//   OBI_E2E_KEEP=1   keep the run folder afterwards
//   OBI_SPHERE_URL   remote mode: run against this deployed Sphere instead of starting one. It writes to
//                    that Sphere (a new e2e-<hex> Sphere per run, left empty behind), so it also needs
//                    SPHERE_OPERATOR_TOKEN and --remote or OBI_E2E_REMOTE=1 (under CI: OBI_E2E_REMOTE=1).
//                    See e2e/SCENARIO.md, "Against a deployed Sphere".
//
// It runs the preflight checks, then the eight scenario steps in order, prints one line per check,
// and exits 0 only when every one passed. A step that isn't implemented yet says so; an
// implemented step after a step that failed or isn't implemented is not run, and says which.
// Every process it starts goes through start() and is stopped when the run ends, however it ends
// (a pass, a failure, an exception, SIGINT or SIGTERM).
//
// Who edits what (docs/ARCHITECTURE.md, section 6): the bodies in `steps` are the Rust core's;
// the rest of this file, and e2e/lib/{fixture,scenario,scenario-doc,snapshot}.mjs, are the lead's.

import { stopGroups } from "./lib/processes.mjs";
import { spawn, execFileSync } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { FIXTURE, buildFixture, git } from "./lib/fixture.mjs";
import {
  AGENT_FLAGS, BRIEF, CANARY, EXPECTED_FINDINGS, EXPECTED_RESULT, OBIS, STUB_PROMPT,
} from "./lib/scenario.mjs";
import { SnapshotError } from "./lib/snapshot.mjs";
import { scenarioDocProblems } from "./lib/scenario-doc.mjs";
import { MIN_NODE_VERSION, requireNodeVersion } from "./lib/node-version.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const OBI_DIR = resolve(here, "..");
const LIVE = process.argv.includes("--live") || process.env.OBI_E2E_MODE === "live";
const env = {
  OBI_SPHERE_DIR: resolve(process.env.OBI_SPHERE_DIR ?? join(OBI_DIR, "..", "obi-sphere")),
  OBID_BIN: resolve(process.env.OBID_BIN ?? join(OBI_DIR, "core", "target", "debug", "obid")),
  STUB_AGENT: join(here, "stub-agent", "stub-agent"),
};
const REMOTE = remoteConfig(); // before anything is created, so a refusal leaves nothing behind
const RUN_DIR = process.env.OBI_E2E_RUN_DIR ? resolve(process.env.OBI_E2E_RUN_DIR) : mkdtempSync(join(tmpdir(), "obi-e2e-"));
mkdirSync(RUN_DIR, { recursive: true });

class NotImplemented extends Error {}
const notImplemented = () => {
  throw new NotImplemented("not implemented");
};
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// Remote mode writes to a deployed Sphere, so it needs three things: its URL, its operator token
// and an explicit opt-in (--remote or OBI_E2E_REMOTE=1; under CI only the variable counts).
// Anything less stops here, before any step. Only the origin is ever printed.
function remoteConfig() {
  const { OBI_SPHERE_URL: url, SPHERE_OPERATOR_TOKEN: token, OBI_E2E_REMOTE, CI } = process.env;
  const asked = process.argv.includes("--remote") || OBI_E2E_REMOTE === "1";
  if (!url && !asked) return null;
  const refuse = (why) => {
    console.error(`Remote mode refused: ${why}`);
    process.exit(2);
  };
  if (!url) refuse("--remote or OBI_E2E_REMOTE=1 is set without OBI_SPHERE_URL.");
  if (!token) refuse("OBI_SPHERE_URL is set without SPHERE_OPERATOR_TOKEN.");
  if (!asked) refuse("OBI_SPHERE_URL is set but this run would write to that Sphere: add --remote or OBI_E2E_REMOTE=1 to say so.");
  if (CI && OBI_E2E_REMOTE !== "1") refuse("CI is set: remote mode there needs OBI_E2E_REMOTE=1, not the flag.");
  let origin;
  try {
    ({ origin } = new URL(url));
  } catch {
    refuse("OBI_SPHERE_URL isn't a URL.");
  }
  if (!/^https?:/.test(origin)) refuse("OBI_SPHERE_URL must be http(s)://host[:port].");
  return { url: origin, token };
}

// Shared between steps: processes, ports, keys, tokens, ids. Filled in as steps run.
const ctx = { runDir: RUN_DIR, live: LIVE, env, processes: [], remote: REMOTE };

// ---------------------------------------------------------------------------------------------
// Processes. Every process the run starts is started here, as the leader of its own process group,
// so stopping it also stops what it started (pnpm starts wrangler, which starts workerd).

// Starts `command` with exactly `env` (nothing inherited), its stdout and stderr appended to `log`.
// `env` is required: Node's spawn gives a child the whole of process.env when it has none, which
// would hand the person's tokens and real HOME to obid, wrangler or an agent, so a call without
// one throws instead. Pass {} for an empty environment.
// Returns the child, with `exited` (a promise of {code, signal}) and `name`.
function start(name, command, args, { cwd, env: childEnv, log, stdio } = {}) {
  if (childEnv === null || typeof childEnv !== "object" || Array.isArray(childEnv)) {
    throw new Error(`start(${name}): no env given; every process gets exactly the environment it is passed, nothing inherited`);
  }
  const child = spawn(command, args, { cwd, env: { ...childEnv }, detached: true, stdio: stdio ?? ["ignore", "pipe", "pipe"] });
  child.name = name;
  child.exited = new Promise((resolveExit) => child.on("exit", (code, signal) => resolveExit({ code, signal })));
  child.on("error", (e) => (child.spawnError = e));
  if (log) {
    mkdirSync(dirname(log), { recursive: true });
    const out = createWriteStream(log, { flags: "a" });
    child.stdout?.pipe(out);
    child.stderr?.pipe(out);
  }
  ctx.processes.push(child);
  return child;
}
ctx.start = start;

// Clean up groups even after a launcher exits before its descendants.
const stopAll = () => stopGroups(ctx.processes);

let finished = false;
async function finish() {
  if (finished) return;
  finished = true;
  if (ctx.remote) console.log(`\n${await (await import("./lib/scenario-steps.mjs")).cleanupRemote(ctx)}`);
  await stopAll();
  if (process.env.OBI_E2E_KEEP === "1") console.log(`Kept ${RUN_DIR}.`);
  else rmSync(RUN_DIR, { recursive: true, force: true });
}

for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143]]) {
  process.on(signal, () => {
    console.log(`\n${signal}: stopping every process the run started.`);
    finish().finally(() => process.exit(code));
  });
}

// ---------------------------------------------------------------------------------------------
// Preflight: what can be checked before anything runs. These may pass today.

// Runs the stub agent alone, with no job sandbox; `sandboxProbe: false` tells it so
// (OBI_STUB_NO_SANDBOX=1), and only the preflight ever does that.
function runStub(worktree, prompt, { sandboxProbe = false } = {}) {
  return new Promise((resolvePromise) => {
    const child = start("stub-agent", env.STUB_AGENT, AGENT_FLAGS, {
      cwd: worktree,
      env: { PATH: process.env.PATH, HOME: worktree, LANG: "C.UTF-8", ...(sandboxProbe ? {} : { OBI_STUB_NO_SANDBOX: "1" }) },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => {
      out += d;
      // Like obid: once the turn's result line is in, close stdin so the agent exits.
      if (out.split("\n").some((l) => l.includes('"type":"result"'))) child.stdin.end();
    });
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => resolvePromise({ code, lines: out.split("\n").filter(Boolean).map((l) => JSON.parse(l)), err }));
    child.stdin.write(JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "text", text: prompt }] } }) + "\n");
  });
}

async function loadSpec() {
  const lib = join(env.OBI_SPHERE_DIR, "spec", "conformance", "lib", "obi.mjs");
  assert(existsSync(lib), `obi-sphere's spec isn't at ${env.OBI_SPHERE_DIR}/spec (set OBI_SPHERE_DIR to an obi-sphere checkout with spec v0.1)`);
  assert(existsSync(join(env.OBI_SPHERE_DIR, "spec", "node_modules")), `obi-sphere's spec has no dependencies installed: run \`pnpm install --frozen-lockfile\` in ${env.OBI_SPHERE_DIR}/spec (make e2e does)`);
  return import(pathToFileURL(lib).href);
}

const preflight = [
  {
    title: `Node ${MIN_NODE_VERSION} or later`,
    run: async () => {
      requireNodeVersion(process.versions.node);
      return `Node ${process.versions.node}`;
    },
  },
  {
    title: "git is installed",
    run: async () => {
      try {
        return execFileSync("git", ["--version"], { encoding: "utf8" }).trim();
      } catch {
        throw new Error("git isn't on PATH: the fixture repository and obid's worktrees need it");
      }
    },
  },
  {
    title: "fixture repository builds with the pinned commit ids, and its tests pass",
    run: async () => {
      ctx.fixture = buildFixture(join(RUN_DIR, "fixture"));
      assert(ctx.fixture.baseSha === FIXTURE.baseSha, `main is ${ctx.fixture.baseSha}, SCENARIO.md pins ${FIXTURE.baseSha}`);
      assert(ctx.fixture.headSha === FIXTURE.headSha, `feature/average is ${ctx.fixture.headSha}, SCENARIO.md pins ${FIXTURE.headSha}`);
      assert(BRIEF.head_sha === FIXTURE.headSha, "the brief's head_sha isn't the fixture's head");
      execFileSync("node", ["--test"], { cwd: ctx.fixture.work, stdio: "pipe", env: { PATH: process.env.PATH, HOME: ctx.fixture.work } });
      return `main ${FIXTURE.baseSha.slice(0, 12)}, feature/average ${FIXTURE.headSha.slice(0, 12)}`;
    },
  },
  {
    title: "stub agent reviews the fixture with the two known findings, refuses data in its prompt, and refuses to run without a sandbox",
    run: async () => {
      assert(ctx.fixture, "needs the fixture repository (the check before)");
      const worktree = join(RUN_DIR, "stub-check");
      git(ctx.fixture.work, ["worktree", "add", "-q", "--detach", worktree, FIXTURE.headSha]);
      mkdirSync(join(worktree, ".obi", "inputs"), { recursive: true });
      writeFileSync(join(worktree, ".obi", "inputs", "obi-request.json"), JSON.stringify({ from: OBIS.b.id, from_owner: OBIS.b.owner, type: "review_request", body: BRIEF }, null, 2));
      const good = await runStub(worktree, STUB_PROMPT);
      assert(good.code === 0, `stub-agent exited ${good.code}: ${good.err.trim() || JSON.stringify(good.lines.at(-1))}`);
      assert(same(good.lines.map((l) => l.type), ["system", "assistant", "result"]), `stub-agent printed ${good.lines.map((l) => l.type).join(", ")}`);
      const result = good.lines.at(-1);
      assert(result.subtype === "success" && result.structured_output, "no successful result with structured_output");
      const want = EXPECTED_FINDINGS.map(({ id, ...f }) => f);
      assert(same(result.structured_output.findings, want), `findings differ from SCENARIO.md: ${JSON.stringify(result.structured_output.findings)}`);
      const leaked = await runStub(worktree, `${STUB_PROMPT}\nGoal: ${BRIEF.goal}`);
      assert(leaked.code === 3 && leaked.lines.at(-1)?.is_error, "stub-agent accepted a prompt that carried the request's data text");
      // Unsandboxed, with its probe on (as under obid): it must notice it can write outside its
      // worktree, fail the turn, and leave nothing behind.
      const loose = await runStub(worktree, STUB_PROMPT, { sandboxProbe: true });
      assert(loose.code === 3 && loose.lines.at(-1)?.is_error && /outside its worktree/.test(loose.lines.at(-1)?.result ?? ""), "stub-agent ran with no job sandbox and didn't notice");
      const probes = readdirSync(dirname(worktree)).filter((n) => n.startsWith(".obi-stub-sandbox-probe-"));
      assert(probes.length === 0, `stub-agent left its sandbox probe behind: ${probes.join(", ")}`);
      const dirty = git(worktree, ["status", "--porcelain", "--untracked-files=all"]).split("\n").filter((l) => l && !l.includes(".obi/"));
      assert(dirty.length === 0, `stub-agent changed the worktree: ${dirty.join(", ")}`);
      return "2 findings; canary in the prompt refused; no sandbox noticed; worktree untouched";
    },
  },
  {
    title: "SCENARIO.md, the fixture messages and the harness's values agree, and the messages validate against obi-sphere's spec v0.1",
    run: async () => {
      const drift = scenarioDocProblems();
      assert(drift.length === 0, `SCENARIO.md and the harness disagree: ${drift.join("; ")}`);
      const spec = await loadSpec();
      ctx.spec = spec;
      const verify = join(env.OBI_SPHERE_DIR, "spec", "conformance", "verify.mjs");
      for (const [schema, file] of [["envelope", "review_request.example.json"], ["envelope", "result.example.json"], ["actions/review_request", "brief.json"]]) {
        try {
          execFileSync(process.execPath, [verify, "--schema", schema], { input: readFileSync(join(here, "fixtures", "messages", file)), stdio: ["pipe", "pipe", "pipe"] });
        } catch (e) {
          throw new Error(`${file} doesn't match ${schema}: ${String(e.stdout ?? e.message).trim()}`);
        }
      }
      for (const f of EXPECTED_FINDINGS) assert(spec.findingId(f.file, f.line, f.title) === f.id, `finding ${f.file}:${f.line} should have id ${spec.findingId(f.file, f.line, f.title)}`);
      assert(spec.resultProblems(EXPECTED_RESULT).length === 0, `the expected result isn't consistent: ${spec.resultProblems(EXPECTED_RESULT).join("; ")}`);
      assert(!JSON.stringify(EXPECTED_RESULT).includes(CANARY), "the expected result carries the canary");
      return "SCENARIO.md matches e2e/fixtures/messages and scenario.mjs; brief, review_request and result valid; finding ids match the spec's derivation";
    },
  },
];

// ---------------------------------------------------------------------------------------------
// The scenario. Each step is implemented in Phase 1 by the workstream named in `by`, exactly as
// e2e/SCENARIO.md describes it; set `implemented: true` once its body does that.

const steps = [
  // Each body is in e2e/lib/scenario-steps.mjs (the Rust core's helper file), loaded when the
  // first step runs, so the preflight never depends on it.
  {
    n: 1,
    title: "Sphere up, team created, two Obis invited",
    by: "Sphere server",
    implemented: true,
    // Start the Sphere locally (`pnpm run local`), create Sphere "e2e" with wellington as admin,
    // get the admin token, invite obi-wellington and obi-ernesto, write the policy.
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(1, c),
  },
  {
    n: 2,
    title: "two obids up with stub agents, and paired",
    by: "Rust core + Sphere server",
    implemented: true,
    // Start obid A (wellington) and obid B (ernesto) with the stub agent; for each: make its key,
    // get its card, sign card and delegation as its owner, join with its invitation.
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(2, c),
  },
  {
    n: 3,
    title: "B sends review_request via relay",
    by: "Rust core + Sphere server",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(3, c),
  },
  {
    n: 4,
    title: "A has no remembered decision: inbox, owner accepts and remembers, review job dispatched",
    by: "Rust core",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(4, c),
  },
  {
    n: 5,
    title: "job finishes, publish gate scan is clean, typed result returned via relay",
    by: "Rust core + Sphere server",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(5, c),
  },
  {
    n: 6,
    title: "second review_request accepted from the remembered decision, no inbox",
    by: "Rust core",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(6, c),
  },
  {
    n: 7,
    title: "audit chain holds both exchanges, signed by their senders, and verifies",
    by: "Sphere server",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(7, c),
  },
  {
    n: 8,
    title: "final assertions: findings, inbox once, chain, writes, nothing pushed, clean exit",
    by: "Rust core + Sphere server",
    implemented: true,
    run: async (c) => (await import("./lib/scenario-steps.mjs")).runStep(8, c),
  },
];

// ---------------------------------------------------------------------------------------------

async function run() {
  console.log(`Obi e2e: a review across two Obis (${LIVE ? "live: real Claude Code" : "stub agents"})`);
  console.log(`  OBI_SPHERE_DIR  ${env.OBI_SPHERE_DIR}${existsSync(env.OBI_SPHERE_DIR) ? "" : "  (missing)"}`);
  console.log(`  OBID_BIN        ${env.OBID_BIN}${existsSync(env.OBID_BIN) ? "" : "  (missing)"}`);
  console.log(`  run folder      ${RUN_DIR}`);
  if (ctx.remote) console.log(`  Sphere          ${ctx.remote.url} (deployed: remote mode, a new Sphere id for this run, left empty behind)`);
  let failures = 0;

  console.log("\nPreflight");
  for (const check of preflight) {
    try {
      const note = await check.run();
      console.log(`  PASS  ${check.title}${note ? ` (${note})` : ""}`);
    } catch (e) {
      failures++;
      console.log(`  FAIL  ${check.title}: ${e.message}`);
    }
  }

  console.log("\nScenario");
  // Why the steps after this point can't run: a failed preflight, or an earlier step that failed
  // or isn't implemented (every step builds on the ones before it).
  let blockedBy = failures ? "the preflight failed" : null;
  let green = 0;
  for (const step of steps) {
    const label = `step ${step.n} (${step.title})`;
    if (!step.implemented) {
      failures++;
      blockedBy ??= `step ${step.n} isn't implemented`;
      console.log(`  FAIL  ${label}: not implemented [${step.by}]`);
      continue;
    }
    if (blockedBy) {
      failures++;
      console.log(`  FAIL  ${label}: not run, ${blockedBy} [${step.by}]`);
      continue;
    }
    try {
      await step.run(ctx);
      green++;
      console.log(`  PASS  ${label}`);
    } catch (e) {
      failures++;
      blockedBy = `step ${step.n} failed`;
      console.log(`  FAIL  ${label}: ${e.message} [${e instanceof SnapshotError ? "harness snapshot" : step.by}]`);
    }
  }

  console.log(`\n${green} of ${steps.length} scenario steps green; ${failures} check(s) failed.`);
  return failures === 0;
}

let passed = false;
try {
  passed = await run();
} catch (e) {
  console.log(`\nThe harness itself failed: ${e.stack ?? e}`);
} finally {
  await finish();
}
process.exit(passed ? 0 : 1);
