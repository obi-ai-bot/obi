// The stand-in agents' own sign-in, as obid runs each tool's login (docs/runner-api.md,
// "GET /v1/accounts/{id}/sign-in"):
//   fake-claude auth login                                          prints the link to open, reads
//       the code pasted back on stdin; `good-code#fake` writes $CLAUDE_CONFIG_DIR/.credentials.json
//       and exits 0, anything else exits 1 as Claude Code does ("Login failed"). Meanwhile a child
//       of its own sleeps, and both pids are in $CLAUDE_CONFIG_DIR/login-pids
//   fake-codex login --device-auth -c cli_auth_credentials_store="file"   prints the link and a
//       one-time code in colour, then after 2 seconds writes $CODEX_HOME/auth.json and exits 0
//   fake-cursor login                                               prints the link, then after
//       2 seconds writes its login where Cursor's file store keeps it ($HOME/.cursor/auth.json on
//       macOS, $XDG_CONFIG_HOME/cursor/auth.json elsewhere) and exits 0
// Each login file holds a made-up token and what the login saw (its arguments, folders and
// environment), so the tests can check how obid ran it. Each also prints a made-up secret obid
// must never repeat, and refuses to run with a Claude Code, Anthropic or GitHub variable.

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";

export const SECRET = "FAKE-LOGIN-SECRET-7f3a9c";

const leaked = Object.keys(process.env).filter((name) =>
  name === "CLAUDECODE" || name.startsWith("CLAUDE_CODE_") || name.startsWith("ANTHROPIC_") ||
  name === "GH_TOKEN" || name === "GITHUB_TOKEN" || name === "OBID_API_TOKEN");

const saw = () => ({
  argv: process.argv.slice(2),
  cwd: process.cwd(),
  env: Object.fromEntries(
    ["HOME", "TMPDIR", "PATH", "BROWSER", "NO_OPEN_BROWSER", "CLAUDE_CONFIG_DIR",
     "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODEX_HOME", "CURSOR_CONFIG_DIR", "XDG_CONFIG_HOME",
     "XDG_CACHE_HOME", "NODE_COMPILE_CACHE", "AGENT_CLI_CREDENTIAL_STORE"]
      .filter((name) => name in process.env)
      .map((name) => [name, process.env[name]])),
  names: Object.keys(process.env).sort(),
});

const write = (path) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify({ token: `${SECRET}-token`, saw: saw() }), { mode: 0o600 });
};

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

export async function login(tool) {
  if (leaked.length) {
    process.stderr.write(`leaked: ${leaked.join(", ")}\n`);
    process.exit(3);
  }
  process.stderr.write(`debug: refresh ${SECRET}\n`);
  if (tool === "claude") {
    const child = spawn("sleep", ["300"], { stdio: "ignore" });
    writeFileSync(join(process.env.CLAUDE_CONFIG_DIR, "login-pids"), `${process.pid} ${child.pid}`);
    process.stdout.write("Opening browser to sign in…\n");
    process.stdout.write("If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=fake\n");
    process.stdout.write("Paste code here if prompted > ");
    const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
    for await (const line of lines) {
      if (line === "good-code#fake") {
        write(join(process.env.CLAUDE_CONFIG_DIR, ".credentials.json"));
        process.stdout.write("Login successful.\n");
        process.exit(0);
      }
      process.stdout.write(`Login failed: Request failed with status code 400 (${SECRET})\n`);
      process.exit(1);
    }
    process.exit(1);
  }
  if (tool === "codex") {
    const args = process.argv.slice(2).join(" ");
    if (!args.includes("--device-auth") || !args.includes('cli_auth_credentials_store="file"')) {
      process.stderr.write(`fake-codex: unexpected login ${args}\n`);
      process.exit(2);
    }
    process.stdout.write("\nWelcome to Codex [v\x1b[90m0.162.1\x1b[0m]\n\n");
    process.stdout.write("1. Open this link in your browser and sign in to your account\n");
    process.stdout.write("   \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m\n\n");
    process.stdout.write("2. Enter this one-time code \x1b[90m(expires in 15 minutes)\x1b[0m\n");
    process.stdout.write("   \x1b[94mABCD-EFGHI\x1b[0m\n\n");
    await sleep(2000);
    write(join(process.env.CODEX_HOME, "auth.json"));
    process.exit(0);
  }
  if (tool === "cursor") {
    if (process.env.NO_OPEN_BROWSER !== "1") {
      process.stderr.write("fake-cursor: NO_OPEN_BROWSER isn't 1\n");
      process.exit(2);
    }
    process.stdout.write("Starting login process...\nWaiting for browser authentication...\n");
    process.stdout.write("Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=fake&mode=login\n");
    await sleep(2000);
    write(process.platform === "darwin"
      ? join(process.env.HOME, ".cursor", "auth.json")
      : join(process.env.XDG_CONFIG_HOME, "cursor", "auth.json"));
    process.exit(0);
  }
  process.exit(2);
}
