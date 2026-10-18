// The boxed fake planner's call to the test's state server (support::planner_state): what the call
// got (its arguments, its input on stdin, where it ran and work.md there), answered with the next
// queued plan line, printed as it came.
import { existsSync, readFileSync } from "node:fs";

const [url, ...args] = process.argv.slice(2);
const input = readFileSync(0, "utf8");
const body = JSON.stringify({
  args,
  input,
  pwd: process.cwd(),
  work: existsSync("work.md") ? readFileSync("work.md", "utf8") : null,
});
const answer = await fetch(url, { method: "POST", body, headers: { "content-type": "application/json" } });
process.stdout.write(await answer.text());
