import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";
import test from "node:test";
import { groupRunning, signalGroup, stopGroups } from "./processes.mjs";

for (const stubborn of [false, true]) {
  test(`failure cleanup stops descendants after their launcher exits${stubborn ? ", escalating SIGTERM" : ""}`, { timeout: 5000 }, async () => {
    const descendant = `${stubborn ? 'process.on("SIGTERM", () => {});' : ''} console.log("ready"); setInterval(() => {}, 1000);`;
    const script = `const { spawn } = require("node:child_process"); const c = spawn(process.execPath, ["-e", ${JSON.stringify(descendant)}], { stdio: ["ignore", "pipe", "ignore"] }); c.stdout.once("data", () => process.exit(0));`;
    const launcher = spawn(process.execPath, ["-e", script], { detached: true, stdio: "ignore" });
    try {
      await once(launcher, "exit");
      assert(groupRunning(launcher.pid), "fixture must leave a live descendant");
      await stopGroups([launcher], 200);
      const deadline = Date.now() + 2000;
      while (groupRunning(launcher.pid) && Date.now() < deadline) await sleep(50);
      assert(!groupRunning(launcher.pid), "cleanup left a live descendant");
    } finally { if (groupRunning(launcher.pid)) signalGroup(launcher.pid, "SIGKILL"); }
  });
}
