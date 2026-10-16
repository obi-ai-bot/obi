import assert from "node:assert/strict";
import { test } from "node:test";
import { requireNodeVersion } from "./node-version.mjs";

// Early Node 22 passed the old major-only check despite incompatible dependencies.
test("rejects Node below Sphere's minimum, including pnpm-compatible early Node 22", () => {
  for (const version of ["20.20.0", "21.99.0", "22.0.0", "22.12.0", "22.13.0", "22.17.9"]) {
    assert.throws(() => requireNodeVersion(version), {
      message: `Node ${version}; the harness and obi-sphere need 22.18 or later`,
    });
  }
});

test("accepts the minimum, later patches and later major versions", () => {
  for (const version of ["22.18.0", "22.18.1", "22.23.1", "23.0.0", "24.0.0"]) {
    assert.doesNotThrow(() => requireNodeVersion(version));
  }
});
