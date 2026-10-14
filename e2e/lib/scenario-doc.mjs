// Checks that e2e/SCENARIO.md and the values the harness uses (scenario.mjs, fixture.mjs and
// e2e/fixtures/messages/) say the same thing, so neither drifts from the other unnoticed. Used by
// the preflight; it reads the document as data and runs nothing from it.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { FIXTURE } from "./fixture.mjs";
import { SNAPSHOT_EXCLUDES, excluded } from "./snapshot.mjs";
import {
  ADMIN_SCOPES, BRIEF, EXPECTED_DECISION, EXPECTED_RESULT, EXPIRES_IN, INBOX_ANSWER, INBOX_OPTIONS,
  OBI_SCOPES, OBIS, POLICY_RULES, SPHERE,
} from "./scenario.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const SCENARIO_MD = join(here, "..", "SCENARIO.md");

const same = (a, b) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  return v;
}

// The text of a section: from its heading line to the next heading of the same or a higher level.
function section(doc, heading) {
  const lines = doc.split("\n");
  const start = lines.findIndex((l) => l.trim() === heading);
  if (start < 0) throw new Error(`SCENARIO.md has no heading "${heading}"`);
  const level = heading.match(/^#+/)[0].length;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const m = lines[i].match(/^(#+) /);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  return lines.slice(start + 1, end).join("\n");
}

function jsonBlocks(text) {
  return [...text.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => m[1]);
}

// The first inline JSON object in `text` that starts with `prefix`, parsed.
function inlineJson(text, prefix) {
  const at = text.indexOf(prefix);
  if (at < 0) throw new Error(`SCENARIO.md has no ${prefix}…`);
  let depth = 0;
  let inString = false;
  for (let i = at; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return JSON.parse(text.slice(at, i + 1));
  }
  throw new Error(`SCENARIO.md's ${prefix}… doesn't close`);
}

// A Markdown table row's cells, each without its code-span backticks.
const cells = (row) => row.replace(/^\|\s*|\s*\|$/g, "").split(" | ").map((c) => c.trim().replace(/^`+ ?/, "").replace(/ ?`+$/, ""));

// Every disagreement between SCENARIO.md and the harness's values; empty when they agree.
export function scenarioDocProblems(doc = readFileSync(SCENARIO_MD, "utf8")) {
  const problems = [];
  const check = (what, fn) => {
    try {
      const why = fn();
      if (why) problems.push(`${what}: ${why}`);
    } catch (e) {
      problems.push(`${what}: ${e.message}`);
    }
  };

  check("the brief", () => {
    const [block] = jsonBlocks(section(doc, "### The brief: the review_request body"));
    if (!block) return "no JSON block";
    return same(JSON.parse(block), BRIEF) ? null : "SCENARIO.md's JSON differs from e2e/fixtures/messages/brief.json";
  });

  check("the expected result", () => {
    const text = section(doc, "### The two known findings, and the verdict");
    const block = jsonBlocks(text).find((b) => b.includes('"outcome"'));
    if (!block) return "no JSON block";
    const placeholder = /"findings": \[[^\]]*\],/;
    if (!placeholder.test(block)) return "no findings line";
    const shown = JSON.parse(block.replace(placeholder, ""));
    const { findings, ...rest } = EXPECTED_RESULT;
    if (!same(shown, rest)) return "SCENARIO.md's JSON differs from e2e/fixtures/messages/result.example.json's body (findings aside)";
    const rows = text.split("\n").filter((l) => /^\| `f-[0-9a-f]{16}` \|/.test(l)).map(cells);
    const table = rows.map(([id, severity, file, line, title]) => ({ id, severity, file, line: Number(line), title }));
    const want = findings.map(({ id, severity, file, line, title }) => ({ id, severity, file, line, title }));
    return same(table, want) ? null : `the findings table says ${JSON.stringify(table)}, result.example.json ${JSON.stringify(want)}`;
  });

  check("the fixture commits", () => {
    const text = section(doc, "### The fixture repository");
    for (const [branch, sha] of [[FIXTURE.baseBranch, FIXTURE.baseSha], [FIXTURE.headBranch, FIXTURE.headSha]]) {
      if (!text.includes(`| \`${branch}\` | \`${sha}\` |`)) return `the table doesn't pin ${branch} at ${sha} (fixture.mjs)`;
    }
    return null;
  });

  check("the fixed values", () => {
    const text = section(doc, "## The fixed values");
    if (!text.includes(`| Sphere | \`${SPHERE.id}\`, named \`${SPHERE.name}\``)) return "the Sphere row differs from scenario.mjs";
    for (const obi of Object.values(OBIS)) {
      if (!text.includes(`\`${obi.id}\`, owner \`${obi.owner}\`, named \`${obi.name}\`, accepts \`${JSON.stringify(obi.accepts)}\``)) return `the row for ${obi.id} differs from scenario.mjs`;
    }
    if (!same([inlineJson(text, '{"id": "team-reviews"')], POLICY_RULES)) return "the policy rule differs from scenario.mjs";
    if (!text.includes(`| \`${OBI_SCOPES}\` |`)) return "the Obi scopes differ from scenario.mjs";
    if (!text.includes(`| \`${ADMIN_SCOPES}\` |`)) return "the admin scopes differ from scenario.mjs";
    return null;
  });

  check("the decision and the inbox answer", () => {
    const text = section(doc, "### The decision and the inbox answer");
    if (!text.includes(INBOX_OPTIONS.map((o) => `\`${o}\``).join(", "))) return "the options differ from scenario.mjs";
    if (!text.includes(`The test answers \`${INBOX_ANSWER}\``)) return "the answer differs from scenario.mjs";
    return same(inlineJson(text, '{"type": "review_request"'), EXPECTED_DECISION) ? null : "the decision differs from scenario.mjs";
  });

  check("the snapshot exclusions", () => {
    const text = section(doc, '## "No process wrote outside its write root"');
    const rows = { obi: "The obi checkout", obiSphere: "The obi-sphere checkout", fixture: "`R/fixture/`" };
    for (const [key, label] of Object.entries(rows)) {
      const row = text.split("\n").find((l) => l.startsWith(`   | ${label} |`));
      if (!row) return `no row for ${label} in step 8.4.1's table`;
      const cell = row.trim().replace(/^\|\s*|\s*\|$/g, "").split(" | ")[1].trim();
      const listed = cell === "nothing" ? [] : [...cell.matchAll(/`([^`]+)`/g)].map((m) => m[1]);
      if (!same(listed, SNAPSHOT_EXCLUDES[key])) return `${label}: SCENARIO.md lists ${JSON.stringify(listed)}, snapshot.mjs ${JSON.stringify(SNAPSHOT_EXCLUDES[key])}`;
    }
    // What the patterns mean (step 8.4.1), checked on the matcher snapshot() uses.
    const cases = [
      ["server/node_modules", SNAPSHOT_EXCLUDES.obiSphere, true],
      ["node_modules", SNAPSHOT_EXCLUDES.obiSphere, true],
      ["spec/node_modules", SNAPSHOT_EXCLUDES.obiSphere, true],
      ["server/.wrangler", SNAPSHOT_EXCLUDES.obiSphere, true],
      ["server/my_node_modules", SNAPSHOT_EXCLUDES.obiSphere, false],
      ["server/.mf", SNAPSHOT_EXCLUDES.obiSphere, false],
      ["spec/.wrangler", SNAPSHOT_EXCLUDES.obiSphere, false],
      ["e2e/.git", SNAPSHOT_EXCLUDES.obi, false],
      ["core/target", SNAPSHOT_EXCLUDES.obi, true],
      ["core/targets", SNAPSHOT_EXCLUDES.obi, false],
    ];
    const wrong = cases.filter(([rel, patterns, want]) => excluded(rel, patterns) !== want);
    return wrong.length ? `snapshot()'s matcher gets ${wrong.map(([rel, , want]) => `${rel} (${want ? "should skip" : "shouldn't skip"})`).join(", ")} wrong` : null;
  });

  check("the expiry", () => (doc.includes(`the requests by \`expiresIn: ${EXPIRES_IN}\``) ? null : `SCENARIO.md doesn't say expiresIn ${EXPIRES_IN}`));
  return problems;
}
