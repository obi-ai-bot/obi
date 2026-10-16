// A launcher can exit before its children. Track groups independently of the
// leader's exit status, and ignore zombies (already exited, waiting for init).
import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

export function groupRunning(pid) {
  try { process.kill(-pid, 0); }
  catch (error) { if (error.code === "ESRCH") return false; if (error.code !== "EPERM") throw error; }
  return execFileSync("ps", ["-axo", "pgid=,stat="], { encoding: "utf8" }).trim().split("\n")
    .some((row) => {
      const [group, state] = row.trim().split(/\s+/);
      return Number(group) === pid && !state.startsWith("Z");
    });
}

export function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); }
  catch (error) { if (error.code !== "ESRCH") throw error; }
}

export async function stopGroups(children, graceMs = 10_000) {
  const groups = children.filter((child) => child.pid && groupRunning(child.pid));
  for (const child of groups) signalGroup(child.pid, "SIGTERM");
  const deadline = Date.now() + graceMs;
  while (groups.some((child) => groupRunning(child.pid)) && Date.now() < deadline) await sleep(100);
  for (const child of groups) if (groupRunning(child.pid)) signalGroup(child.pid, "SIGKILL");
}
