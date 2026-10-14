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
//
// It runs the preflight checks, then the eight scenario steps in order, prints one line per check,
// and exits 0 only when every one passed. A step that isn't implemented yet says so; once steps
// are implemented, a failed step marks the implemented steps after it as not run.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { FIXTURE, buildFixture, git } from "./lib/fixture.mjs";
import {
  AGENT_FLAGS, BRIEF, CANARY, EXPECTED_FINDINGS, EXPECTED_RESULT, OBIS, STUB_PROMPT,
} from "./lib/scenario.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const OBI_DIR = resolve(here, "..");
const LIVE = process.argv.includes("--live") || process.env.OBI_E2E_MODE === "live";
const env = {
  OBI_SPHERE_DIR: resolve(process.env.OBI_SPHERE_DIR ?? join(OBI_DIR, "..", "obi-sphere")),
  OBID_BIN: resolve(process.env.OBID_BIN ?? join(OBI_DIR, "core", "target", "debug", "obid")),
  STUB_AGENT: join(here, "stub-agent", "stub-agent"),
};
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

// Shared between steps: processes, ports, keys, tokens, ids. Filled in as steps run.
const ctx = { runDir: RUN_DIR, live: LIVE, env, processes: [] };

// ---------------------------------------------------------------------------------------------
// Preflight: what can be checked before anything runs. These may pass today.

function runStub(worktree, prompt) {
  return new Promise((resolvePromise) => {
    const child = spawn(env.STUB_AGENT, AGENT_FLAGS, {
      cwd: worktree,
      env: { PATH: process.env.PATH, HOME: worktree, LANG: "C.UTF-8" },
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
    title: "Node 22 or later",
    run: async () => {
      const major = Number(process.versions.node.split(".")[0]);
      assert(major >= 22, `Node ${process.versions.node}; the harness and wrangler need 22 or later`);
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
    title: "stub agent reviews the fixture with the two known findings, and refuses data in its prompt",
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
      const dirty = git(worktree, ["status", "--porcelain", "--untracked-files=all"]).split("\n").filter((l) => l && !l.includes(".obi/"));
      assert(dirty.length === 0, `stub-agent changed the worktree: ${dirty.join(", ")}`);
      return "2 findings; canary in the prompt refused; worktree untouched";
    },
  },
  {
    title: "SCENARIO.md's review_request and result validate against obi-sphere's spec v0.1",
    run: async () => {
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
      return "brief, review_request and result valid; finding ids match the spec's derivation";
    },
  },
];

// ---------------------------------------------------------------------------------------------
// The scenario. Each step is implemented in Phase 1 by the workstream named in `by`, exactly as
// e2e/SCENARIO.md describes it; set `implemented: true` once its body does that.

const steps = [
  {
    n: 1,
    title: "Sphere up, team created, two Obis invited",
    by: "Sphere server",
    implemented: false,
    // Start the Sphere locally (`pnpm run local`), create Sphere "e2e" with wellington as admin,
    // get the admin token, invite obi-wellington and obi-ernesto, write the policy.
    run: notImplemented,
  },
  {
    n: 2,
    title: "two obids up with stub agents, and paired",
    by: "Rust core + Sphere server",
    implemented: false,
    // Start obid A (wellington) and obid B (ernesto) with the stub agent; for each: make its key,
    // get its card, sign card and delegation as its owner, join with its invitation.
    run: notImplemented,
  },
  {
    n: 3,
    title: "B sends review_request via relay",
    by: "Rust core + Sphere server",
    implemented: false,
    run: notImplemented,
  },
  {
    n: 4,
    title: "A has no remembered decision: inbox, owner accepts and remembers, review job dispatched",
    by: "Rust core",
    implemented: false,
    run: notImplemented,
  },
  {
    n: 5,
    title: "job finishes, publish gate scan is clean, typed result returned via relay",
    by: "Rust core + Sphere server",
    implemented: false,
    run: notImplemented,
  },
  {
    n: 6,
    title: "second review_request accepted from the remembered decision, no inbox",
    by: "Rust core",
    implemented: false,
    run: notImplemented,
  },
  {
    n: 7,
    title: "audit chain holds both exchanges, signed by their senders, and verifies",
    by: "Sphere server",
    implemented: false,
    run: notImplemented,
  },
  {
    n: 8,
    title: "final assertions: findings, inbox once, chain, writes, nothing pushed, clean exit",
    by: "Rust core + Sphere server",
    implemented: false,
    run: notImplemented,
  },
];

// ---------------------------------------------------------------------------------------------

async function main() {
  console.log(`Obi e2e: a review across two Obis (${LIVE ? "live: real Claude Code" : "stub agents"})`);
  console.log(`  OBI_SPHERE_DIR  ${env.OBI_SPHERE_DIR}${existsSync(env.OBI_SPHERE_DIR) ? "" : "  (missing)"}`);
  console.log(`  OBID_BIN        ${env.OBID_BIN}${existsSync(env.OBID_BIN) ? "" : "  (missing)"}`);
  console.log(`  run folder      ${RUN_DIR}`);
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
  let blockedBy = failures ? "preflight" : null;
  let green = 0;
  for (const step of steps) {
    const label = `step ${step.n} (${step.title})`;
    if (!step.implemented) {
      failures++;
      console.log(`  FAIL  ${label}: not implemented [${step.by}]`);
      continue;
    }
    if (blockedBy) {
      failures++;
      console.log(`  FAIL  ${label}: not run, ${blockedBy} failed [${step.by}]`);
      continue;
    }
    try {
      await step.run(ctx);
      green++;
      console.log(`  PASS  ${label}`);
    } catch (e) {
      failures++;
      blockedBy = `step ${step.n}`;
      console.log(`  FAIL  ${label}: ${e.message} [${step.by}]`);
    }
  }

  for (const p of ctx.processes) p.kill?.("SIGTERM");
  console.log(`\n${green} of ${steps.length} scenario steps green; ${failures} check(s) failed.`);
  if (process.env.OBI_E2E_KEEP === "1") console.log(`Kept ${RUN_DIR}.`);
  else rmSync(RUN_DIR, { recursive: true, force: true });
  return failures === 0;
}

process.exit((await main()) ? 0 : 1);
