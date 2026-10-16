import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { changes, snapshot, SnapshotError, SNAPSHOT_EXCLUDES } from "./snapshot.mjs";

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "snapshot-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

const digest = (value) => createHash("sha256").update(value).digest("hex");

test("snapshots preserve files, links, exclusions and change reporting", (t) => {
  const root = fixture(t);
  const content = Buffer.alloc(1024 * 1024 + 37, 0x61);
  writeFileSync(join(root, "file"), content);
  writeFileSync(join(root, "empty"), "");
  symlinkSync("missing-target", join(root, "link"));
  mkdirSync(join(root, "nested", "node_modules"), { recursive: true });
  writeFileSync(join(root, "nested", "node_modules", "ignored"), "ignored");
  const before = snapshot(root, ["**/node_modules/"]);
  assert.deepEqual(before, new Map([
    ["empty", `0 ${digest("")}`],
    ["file", `${content.length} ${digest(content)}`],
    ["link", "link missing-target"],
  ]));
  writeFileSync(join(root, "file"), "changed");
  rmSync(join(root, "empty"));
  writeFileSync(join(root, "added"), "new");
  assert.deepEqual(changes(before, snapshot(root, ["**/node_modules/"])), [
    "added added", "changed file", "removed empty",
  ]);
});

test("hashes a sparse file larger than 2 GiB with bounded memory", (t) => {
  const root = fixture(t);
  // The old readFileSync implementation throws ERR_FS_FILE_TOO_LARGE for this file.
  const size = 2 ** 31 + 17;
  mkdirSync(join(root, ".build"));
  const path = join(root, ".build", "large");
  writeFileSync(path, "");
  truncateSync(path, size);
  // Independently compute the expected digest without materializing the sparse file.
  const zeroes = Buffer.alloc(4 * 1024 * 1024);
  const hash = createHash("sha256");
  for (let left = size; left > 0; left -= zeroes.length) {
    hash.update(zeroes.subarray(0, Math.min(left, zeroes.length)));
  }
  assert.equal(snapshot(root, SNAPSHOT_EXCLUDES.obi).get(".build/large"), `${size} ${hash.digest("hex")}`);
});

test("snapshot I/O failures identify the harness operation, path and original cause", (t) => {
  const missing = join(fixture(t), "missing");
  assert.throws(() => snapshot(missing), (error) => {
    assert.ok(error instanceof SnapshotError);
    assert.match(error.message, /snapshot .*missing:/);
    assert.equal(error.cause.code, "ENOENT");
    assert.equal(error.cause.path, missing);
    return true;
  });
});
