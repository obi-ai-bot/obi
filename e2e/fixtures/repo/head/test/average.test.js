import { test } from "node:test";
import assert from "node:assert/strict";
import { average } from "../src/average.js";

test("average of three numbers", () => {
  assert.equal(average([1, 2, 3]), 2);
});
