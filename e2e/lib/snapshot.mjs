// What the "no process wrote outside its write root" check compares (e2e/SCENARIO.md, step 8.4.1):
// every file under a folder, by path, size and SHA-256. Taken before step 1 and after step 8.

import { createHash } from "node:crypto";
import { closeSync, lstatSync, openSync, readdirSync, readlinkSync, readSync } from "node:fs";
import { join, relative, sep } from "node:path";

// The folders step 8.4.1 leaves out of each snapshot, as SCENARIO.md's table lists them. Each is a
// path pattern (see `excluded`): `a/b/` is that folder only, `**/name/` every folder called `name`.
export const SNAPSHOT_EXCLUDES = {
  obi: [".git/", "core/target/"],
  obiSphere: [".git/", "**/node_modules/", "server/.wrangler/"],
  fixture: [],
};

// Whether the folder at `rel` (relative to the snapshot's root, "/"-separated, no trailing "/")
// is skipped by one of `patterns`. A pattern ends in "/" and names a folder:
//   "a/b/"        the folder a/b at that place only
//   "**/name/"    every folder whose last segment is `name`, at any depth (the top level too)
// Whole segments only: "**/node_modules/" doesn't match "my_node_modules".
export function excluded(rel, patterns) {
  for (const pattern of patterns) {
    if (!pattern.endsWith("/")) throw new Error(`snapshot pattern ${pattern} doesn't end in "/"`);
    const body = pattern.slice(0, -1);
    if (body.startsWith("**/")) {
      const name = body.slice(3);
      if (name.includes("/") || name.includes("*") || !name) throw new Error(`snapshot pattern ${pattern}: "**/" takes one folder name`);
      if (rel.split("/").at(-1) === name) return true;
    } else {
      if (body.includes("*")) throw new Error(`snapshot pattern ${pattern}: "*" only as a leading "**/"`);
      if (rel === body) return true;
    }
  }
  return false;
}

// Snapshot I/O is the harness's responsibility, even when a scenario step takes the snapshot.
export class SnapshotError extends Error {
  constructor(path, cause) {
    super(`snapshot ${path}: ${cause.message}`, { cause });
    this.name = "SnapshotError";
  }
}

// Feed SHA-256 bounded chunks: readFileSync cannot read files larger than 2 GiB.
function hashFile(path, buffer) {
  const fd = openSync(path, "r");
  try {
    const hash = createHash("sha256");
    let size;
    while ((size = readSync(fd, buffer, 0, buffer.length, null)) !== 0) {
      hash.update(buffer.subarray(0, size));
    }
    return hash.digest("hex");
  } finally {
    closeSync(fd);
  }
}

// Every file under `root` but the folders `skip` excludes (patterns as above), with its size and
// SHA-256 (a symbolic link: its target).
export function snapshot(root, skip = []) {
  const files = new Map();
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let currentPath = root;
  const walk = (dir) => {
    currentPath = dir;
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      currentPath = path;
      const rel = relative(root, path).split(sep).join("/");
      const stat = lstatSync(path);
      if (stat.isDirectory()) {
        if (!excluded(rel, skip)) walk(path);
      } else if (stat.isSymbolicLink()) files.set(rel, `link ${readlinkSync(path)}`);
      else files.set(rel, `${stat.size} ${hashFile(path, buffer)}`);
    }
  };
  try {
    walk(root);
  } catch (cause) {
    throw new SnapshotError(currentPath, cause);
  }
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
