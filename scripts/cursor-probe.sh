#!/bin/sh
# The Cursor probe (#406, spike #24): what only the real `cursor-agent` can say, in two halves.
#
#   scripts/cursor-probe.sh offline     Signed out, in a throwaway HOME. Safe anywhere cursor-agent
#                                       runs: no login, no network call that needs one.
#   scripts/cursor-probe.sh signed-in   Two throwaway account homes you sign in to (two different
#                                       Cursor accounts), then status, models, an edit and a command,
#                                       MCP through `mcpServers`, `session/load`. It never reads a
#                                       token file: it only stats files and asks Cursor for `status`.
#
# Both print a redacted report (emails, tokens and your home folder are masked) to paste into
# docs/cursor.md and the pull request. Nothing is written outside the temporary folder it makes
# and prints. CURSOR_AGENT names the binary (default: cursor-agent). Needs python3.
set -eu
if ! command -v python3 >/dev/null 2>&1; then echo "cursor-probe: python3 is needed." >&2; exit 2; fi
exec python3 -I - "$@" <<'PY'
import hashlib, http.server, json, os, queue, re, shutil, subprocess, sys, tempfile, threading, time

BIN = shutil.which(os.environ.get("CURSOR_AGENT", "cursor-agent")) or ""
REAL_HOME = os.path.expanduser("~")
TIMEOUT = 45


def redact(text):
    text = text.replace(REAL_HOME, "~")
    text = re.sub(r"[\w.+-]+@[\w-]+(\.[\w-]+)+", "<email>", text)
    text = re.sub(r"\b(?:eyJ[\w-]+\.[\w-]+\.[\w-]+|[A-Fa-f0-9]{32,}|[A-Za-z0-9_-]{40,})\b", "<token>", text)
    return text


def say(line=""):
    print(redact(line))


def run(args, env, timeout=TIMEOUT, stdin=None):
    try:
        done = subprocess.run([BIN] + args, env=env, capture_output=True, text=True, timeout=timeout, input=stdin)
        return done.returncode, (done.stdout + done.stderr).strip()
    except subprocess.TimeoutExpired:
        return None, "timed out"


def tree(folder):
    found = []
    for base, _, names in os.walk(folder):
        for name in names:
            found.append(os.path.relpath(os.path.join(base, name), folder))
    return sorted(found)


class Acp:
    """One `cursor-agent acp` process, driven line by line. Permission requests are rejected
    (reject_once) and noted, so the probe changes nothing; `answer` can allow instead."""

    def __init__(self, env, cwd, args=("--sandbox", "disabled")):
        self.process = subprocess.Popen([BIN, *args, "acp"], env=env, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        self.seen = []        # (method, params) of every request and notification
        self.errors = []
        self.next = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: [self.errors.append(l) for l in self.process.stderr], daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            try:
                self.lines.put(json.loads(line))
            except ValueError:
                self.errors.append("not JSON: " + line.strip())
        self.lines.put(None)

    def _send(self, message):
        message["jsonrpc"] = "2.0"
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def call(self, method, params, timeout=TIMEOUT, answer="reject_once"):
        self.next += 1
        wanted = self.next
        self._send({"id": wanted, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.lines.get(timeout=1)
            except queue.Empty:
                continue
            if message is None:
                return {"error": {"message": "the process ended"}}
            if message.get("method"):
                self.seen.append((message["method"], message.get("params")))
                if "id" in message:
                    self._reply(message, answer)
            elif message.get("id") == wanted:
                return message
        return {"error": {"message": "timed out"}}

    def _reply(self, request, answer):
        method = request["method"]
        if method == "session/request_permission":
            options = request["params"].get("options", [])
            pick = next((o for o in options if str(o.get("kind", o.get("optionId", ""))).replace("-", "_") == answer), None)
            outcome = {"outcome": "selected", "optionId": pick["optionId"]} if pick else {"outcome": "cancelled"}
            self._send({"id": request["id"], "result": {"outcome": outcome}})
        elif method == "cursor/ask_question":
            self._send({"id": request["id"], "result": {"outcome": {"outcome": "skipped"}}})
        elif method == "cursor/create_plan":
            self._send({"id": request["id"], "result": {"outcome": {"outcome": "rejected", "reason": "probe"}}})
        else:
            self._send({"id": request["id"], "error": {"code": -32601, "message": "not supported"}})

    def initialize(self):
        return self.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "oby-probe", "version": "0"}})

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


def base_env(home, config=None, xdg=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CURSOR_API", "CURSOR_AUTH"))}
    env["HOME"] = home
    if xdg:
        env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
    else:
        env.pop("XDG_CONFIG_HOME", None)
    if config:
        env["CURSOR_CONFIG_DIR"] = config
    env["NO_OPEN_BROWSER"] = "1"
    return env


def show(title, code, text):
    say(f"### {title}")
    say(f"exit: {code}")
    say(text if text else "(no output)")
    say()


def offline():
    folder = tempfile.mkdtemp(prefix="oby-cursor-probe-")
    home, config = os.path.join(folder, "home"), os.path.join(folder, "cursor")
    os.makedirs(home)
    os.makedirs(config)
    env = base_env(home, config)
    say("# Cursor probe, offline half")
    say(f"binary: {BIN or 'NOT FOUND'}")
    say(f"folder: {folder}")
    say()
    if not BIN:
        say("cursor-agent isn't on PATH: nothing to probe.")
        return 1
    show("cursor-agent --version", *run(["--version"], env))
    show("cursor-agent acp --help", *run(["acp", "--help"], env))
    show("cursor-agent status (signed out)", *run(["status"], env))
    acp = Acp(env, folder)
    say("### initialize")
    say(json.dumps(acp.initialize(), indent=1))
    say()
    say("### session/new while signed out")
    say(json.dumps(acp.call("session/new", {"cwd": folder, "mcpServers": []}), indent=1))
    say()
    if acp.errors:
        say("### stderr")
        say("\n".join(acp.errors[-20:]))
        say()
    acp.close()
    say("### files under a fresh CURSOR_CONFIG_DIR and HOME")
    say("CURSOR_CONFIG_DIR:")
    for name in tree(config):
        say("  " + name)
    say("HOME:")
    for name in tree(home):
        say("  " + name)
    say()
    say(f"(throwaway folder {folder}: delete it when done)")
    return 0


class Stub(http.server.BaseHTTPRequestHandler):
    hits = []

    def _any(self):
        Stub.hits.append(f"{self.command} {self.path}")
        self.send_response(401)
        self.end_headers()

    do_GET = do_POST = do_DELETE = do_OPTIONS = _any

    def log_message(self, *args):
        pass


def identity(env):
    code, text = run(["status"], env)
    return code, text


def signed_in():
    if not BIN:
        say("cursor-agent isn't on PATH: nothing to probe.")
        return 1
    folder = tempfile.mkdtemp(prefix="oby-cursor-probe-")
    homes = {}
    say("# Cursor probe, signed-in half")
    say(f"binary: {BIN}")
    say(f"folder: {folder}")
    say()
    # Each account home keeps its own HOME too, so a login in the real one can't leak in; XDG is
    # tried both ways to find where the login lives.
    for name in ("A", "B"):
        home = os.path.join(folder, name, "home")
        config = os.path.join(folder, name, "cursor")
        os.makedirs(home)
        os.makedirs(config)
        homes[name] = (home, config)
    say("## 1. Where the login lives: CURSOR_CONFIG_DIR only, HOME kept as it is")
    shared = {}
    for name, (home, config) in homes.items():
        env = base_env(REAL_HOME, config)
        code, text = identity(env)
        shared[name] = text
        show(f"status with CURSOR_CONFIG_DIR={name}", code, text)
    say("If both say the same account (or a signed-in one you never logged in to here), the login")
    say("isn't under CURSOR_CONFIG_DIR: CursorFacts.separateLogins stays false.")
    say()
    say("## 2. Sign in to each account (Terminal, in the browser), with HOME and XDG_CONFIG_HOME of its own")
    for name, (home, config) in homes.items():
        env = base_env(home, config, xdg=True)
        code, text = identity(env)
        if code != 0 or re.search(r"(?i)not logged in|signed out|log ?in", text):
            say(f"Account {name} is signed out. In another terminal run, then press Enter here:")
            say(f"  HOME='{home}' XDG_CONFIG_HOME='{home}/.config' CURSOR_CONFIG_DIR='{config}' NO_OPEN_BROWSER=1 {BIN} login")
            sys.stdout.flush()
            sys.stdin = open("/dev/tty") if os.path.exists("/dev/tty") else sys.stdin
            input()
    labels = {}
    for name, (home, config) in homes.items():
        env = base_env(home, config, xdg=True)
        code, text = identity(env)
        labels[name] = text
        show(f"status for {name}", code, text)
        code, text = run(["models"], env)
        show(f"models for {name}", code, text)
    different = labels["A"] != labels["B"] and all(labels.values())
    say(f"separate logins (per HOME + XDG_CONFIG_HOME + CURSOR_CONFIG_DIR): {'yes' if different else 'NO'}")
    say("Files each home holds (names only):")
    for name, (home, config) in homes.items():
        say(f"  {name}: " + ", ".join(tree(home) + ["cursor:" + n for n in tree(config)]))
    say()
    home, config = homes["A"]
    repo = os.path.join(folder, "repo")
    os.makedirs(repo)
    subprocess.run(["git", "init", "-q", repo], check=False)
    with open(os.path.join(repo, "README.md"), "w") as f:
        f.write("probe\n")
    env = base_env(home, config, xdg=True)
    server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    mcp = [{"type": "http", "name": "probe", "url": f"http://127.0.0.1:{server.server_port}/mcp",
            "headers": [{"name": "Authorization", "value": "Bearer probe-token"}]}]
    say("## 3. An edit and a command with --sandbox disabled, every permission rejected")
    acp = Acp(env, repo)
    init = acp.initialize()
    session = acp.call("session/new", {"cwd": repo, "mcpServers": mcp})
    result = session.get("result", {})
    say("initialize result: " + json.dumps(init.get("result", init), indent=1))
    say("session/new result: " + json.dumps(result if result else session, indent=1))
    sid = result.get("sessionId")
    facts = {"loadSession": bool(init.get("result", {}).get("agentCapabilities", {}).get("loadSession")),
             "mcpHttp": bool(init.get("result", {}).get("agentCapabilities", {}).get("mcpCapabilities", {}).get("http")),
             "modelOption": any(o.get("category") == "model" for o in result.get("configOptions", []) or [])}
    asked = {}
    if sid:
        for label, text in (("edit", "Create a file named probe.txt containing the word hello. Use your file edit tool, nothing else."),
                            ("command", "Run the shell command `echo probe` and tell me its output.")):
            before = len(acp.seen)
            reply = acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}, timeout=120)
            requests = [(m, p) for m, p in acp.seen[before:] if m == "session/request_permission"]
            kinds = [(p.get("toolCall") or {}).get("kind") for _, p in requests]
            asked[label] = kinds
            say(f"{label}: permission requests: {kinds or 'none'}; stopReason: {reply.get('result', {}).get('stopReason', reply.get('error'))}")
            if label == "edit":
                say(f"  probe.txt written without asking: {os.path.exists(os.path.join(repo, 'probe.txt'))}")
        say("methods seen: " + ", ".join(sorted({m for m, _ in acp.seen})))
        say()
        say("## 4. MCP through mcpServers (did Cursor reach the stub server?)")
        acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "List the tools of your MCP server named probe, if you have one."}]}, timeout=90)
        facts["honoursMcpServers"] = bool(Stub.hits)
        say(f"stub requests: {Stub.hits or 'none'}")
    say()
    acp.close()
    say("## 5. session/load in a new process")
    if sid:
        again = Acp(env, repo)
        again.initialize()
        loaded = again.call("session/load", {"sessionId": sid, "cwd": repo, "mcpServers": []}, timeout=60)
        say("session/load: " + json.dumps(loaded.get("error") or "ok"))
        again.close()
    say()
    say("## Summary for CursorFacts (Engine/Cursor.swift)")
    say(f"separateLogins = {str(different).lower()}")
    say(f"editsAsk = {str(bool(asked.get('edit'))).lower()}")
    say(f"honoursMcpServers = {str(bool(facts.get('honoursMcpServers'))).lower()}")
    say(f"modelOption = {str(facts['modelOption']).lower()}")
    say(f"(loadSession = {facts['loadSession']}, mcp http = {facts['mcpHttp']}; commands asked: {asked.get('command')})")
    say(f"(throwaway folder {folder}: delete it when done)")
    return 0


mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "offline":
    sys.exit(offline())
if mode == "signed-in":
    sys.exit(signed_in())
print("usage: scripts/cursor-probe.sh offline | signed-in", file=sys.stderr)
sys.exit(2)
PY
