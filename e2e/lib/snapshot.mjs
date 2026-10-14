// What the "no process wrote outside its worktree" check compares (e2e/SCENARIO.md, step 8): every
// file under a folder, by path, size and SHA-256. Taken before step 1 and after step 8.

import { createHash } from "node:crypto";
import { lstatSync, readdirSync, readFileSync, readlinkSync } from "node:fs";
import { join, relative } from "node:path";

// skip: paths (relative to root) whose whole subtree is a write root of some process.
export function snapshot(root, skip = []) {
  const files = new Map();
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      const rel = relative(root, path);
      if (skip.some((s) => rel === s || rel.startsWith(s + "/"))) continue;
      const stat = lstatSync(path);
      if (stat.isDirectory()) walk(path);
      else if (stat.isSymbolicLink()) files.set(rel, `link ${readlinkSync(path)}`);
      else files.set(rel, `${stat.size} ${createHash("sha256").update(readFileSync(path)).digest("hex")}`);
    }
  };
  walk(root);
  return files;
}

// The paths added, removed or changed between two snapshots of the same root.
export function changes(before, after) {
  const out = [];
  for (const [path, value] of after) {
    if (!before.has(path)) out.push(`added ${path}`);
    else if (before.get(path) !== value) out.push(`changed ${path}`);
  }
  for (const path of before.keys()) if (!after.has(path)) out.push(`removed ${path}`);
  return out.sort();
}
