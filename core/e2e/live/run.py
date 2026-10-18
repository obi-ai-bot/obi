#!/usr/bin/env python3
"""Live end-to-end test of talking to Oby, against the real agents (README.md next to this file).

    python3 core/e2e/live/run.py --obid core/target/debug/obid

Starts the given obid on a free port with a throwaway home, follows GET /v1/events, talks to it
with POST /v1/plans, runs the scenarios below, prints a pass/fail table and every failure's
events (tokens redacted), then stops obid and deletes the home. Python 3 standard library only.
"""

import argparse
import http.client
import json
import os
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib

ACCOUNT_ID = "deskree"
ACCOUNT_NAME = "Deskree"
# ponytail: the one Claude account that works on this Mac today; the default/Personal login is
# revoked, so it's never used. --account-dir to point at another.
ACCOUNT_DIR = (
    "/Users/wellprado/Library/Application Support/Oby/accounts/32203c5b-b24c-4353-bdcb-f34797790d0a"
)
REPO = "field/fixture-app"
REMOTE = "file:///Users/wellprado/Projects/Deskree/oby-field/remote.git"
CODEWORD = "PAPAYA-42"
TURN_TIMEOUT = 700  # the harness's turn budget is 600 s by default
TERMINAL = {"done", "failed", "stopped", "interrupted"}


# --- redaction --------------------------------------------------------------------------------

SECRET_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]+"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]+"),
    re.compile(r'(?i)("(?:[a-z_]*token|accessToken|refreshToken|apiKey|password|secret)"\s*:\s*")[^"]*'),
]


def redact(text, secrets):
    for s in secrets:
        if s:
            text = text.replace(s, "[redacted]")
    for p in SECRET_PATTERNS:
        text = p.sub(lambda m: (m.group(1) if m.groups() else "") + "[redacted]", text)
    return text


# --- obid -------------------------------------------------------------------------------------


class Obid:
    def __init__(self, binary, run_dir, account_dir, remote):
        self.run = run_dir
        self.home = os.path.join(run_dir, "home")
        os.makedirs(self.home, mode=0o700)
        os.makedirs(os.path.join(run_dir, "tmp"), mode=0o700)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        config = {
            "listen": f"127.0.0.1:{self.port}",
            "home": self.home,
            "owner": "e2e-live",
            "telemetry": False,
            "claudeKeychain": True,
            "vault": {"store": "file"},
            "allowFileRemotes": True,
            "agents": {
                "claude": {
                    "bin": "claude",
                    "accounts": [{"id": ACCOUNT_ID, "name": ACCOUNT_NAME, "configDir": account_dir}],
                }
            },
            "repos": [{"repo": REPO, "remote": remote, "defaultBranch": "main", "check": "node --test"}],
        }
        self.config_path = os.path.join(run_dir, "config.json")
        with open(self.config_path, "w") as f:
            json.dump(config, f, indent=2)
        env = {
            k: v
            for k, v in os.environ.items()
            if not (k == "CLAUDECODE" or k.startswith(("CLAUDE_CODE_", "ANTHROPIC_")) or k == "OBID_API_TOKEN")
        }
        env["TMPDIR"] = os.path.join(run_dir, "tmp")
        self.log_path = os.path.join(run_dir, "obid.log")
        self.log = open(self.log_path, "wb")
        self.proc = subprocess.Popen(
            [binary, "serve", "--config", self.config_path],
            stdout=self.log,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        self.token = None
        self.events = []  # (seconds since start, event, data)
        self.cond = threading.Condition()
        self.t0 = time.monotonic()
        self._ready()
        threading.Thread(target=self._follow, daemon=True).start()
        self.wait_for(lambda e: e[1] == "ready", 10)

    def _ready(self):
        deadline = time.monotonic() + 30
        token_file = os.path.join(self.home, "api-token")
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"obid exited {self.proc.returncode}: {self.tail()}")
            if self.token is None and os.path.exists(token_file):
                self.token = open(token_file).read().strip() or None
            if self.token:
                try:
                    if self.request("GET", "/v1/status")[0] == 200:
                        return
                except OSError:
                    pass
            time.sleep(0.2)
        raise RuntimeError(f"obid didn't answer in 30 s: {self.tail()}")

    def tail(self):
        if not self.log.closed:
            self.log.flush()
        with open(self.log_path, "rb") as f:
            return f.read()[-2000:].decode(errors="replace")

    def request(self, method, path, body=None, timeout=30):
        """(status, headers, parsed body or raw text)."""
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                status, headers, raw = r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            status, headers, raw = e.code, dict(e.headers), e.read()
        try:
            return status, headers, json.loads(raw)
        except ValueError:
            return status, headers, raw.decode(errors="replace")

    def _follow(self):
        while self.proc.poll() is None:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=None)
                conn.request("GET", "/v1/events", headers={"Authorization": f"Bearer {self.token}"})
                resp = conn.getresponse()
                self._add("ready", {})
                name, data = "message", []
                while True:
                    line = resp.readline()
                    if not line:
                        break
                    line = line.decode(errors="replace").rstrip("\r\n")  # split on \n only
                    if line.startswith("event:"):
                        name = line[6:].strip()
                    elif line.startswith("data:"):
                        data.append(line[5:].lstrip())
                    elif line == "" and data:
                        try:
                            parsed = json.loads("\n".join(data))
                        except ValueError:
                            parsed = "\n".join(data)
                        self._add(name, parsed)
                        name, data = "message", []
            except OSError:
                pass
            time.sleep(0.5)

    def _add(self, name, data):
        with self.cond:
            self.events.append((time.monotonic() - self.t0, name, data))
            self.cond.notify_all()

    def mark(self):
        with self.cond:
            return len(self.events)

    def since(self, mark):
        with self.cond:
            return list(self.events[mark:])

    def wait_for(self, pred, timeout, start=0):
        """The first event from `start` on that `pred` holds for, or None after `timeout` s."""
        deadline = time.monotonic() + timeout
        with self.cond:
            i = start
            while True:
                while i < len(self.events):
                    if pred(self.events[i]):
                        return self.events[i]
                    i += 1
                left = deadline - time.monotonic()
                if left <= 0 or self.proc.poll() is not None:
                    return None
                self.cond.wait(min(left, 1))

    def say(self, said, conversation=None, **extra):
        body = {"said": said, **extra}
        if conversation:
            body["conversation"] = conversation
        elif "new" not in extra:
            body["new"] = True
        status, _, answer = self.request("POST", "/v1/plans", body, timeout=TURN_TIMEOUT)
        return status, answer

    def stop(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        self.log.close()


def rmtree(path):
    def writable(func, p, _):
        os.chmod(os.path.dirname(p), stat.S_IRWXU)
        os.chmod(p, stat.S_IRWXU) if os.path.exists(p) else None
        func(p)

    shutil.rmtree(path, onexc=writable) if sys.version_info >= (3, 12) else shutil.rmtree(path, onerror=writable)


# --- scenarios --------------------------------------------------------------------------------


class Skip(Exception):
    pass


class Fail(Exception):
    pass


def check(ok, why):
    if not ok:
        raise Fail(why)


def answer_text(answer):
    if not isinstance(answer, dict):
        return str(answer)
    return " ".join(str(answer.get(k) or "") for k in ("reply", "text", "said", "question")).strip()


def oby_turn(o, mark, conversation):
    """Oby's `turn` event in `conversation` since `mark`: it can come just after the answer."""
    e = o.wait_for(lambda e: e[1] == "turn" and isinstance(e[2], dict) and e[2].get("conversation") == conversation
                   and e[2].get("who") == "oby", 5, mark)
    return e and e[2]


def conv_events(o, mark, conversation, name):
    return [d for _, n, d in o.since(mark) if n == name and isinstance(d, dict) and d.get("conversation") == conversation]


class Suite:
    def __init__(self, o, has_harness, job_timeout):
        self.o = o
        self.harness = has_harness
        self.job_timeout = job_timeout
        self.conv1 = None
        self.job = None  # scenario 4's job id
        self.job_conv = None
        self.job_ended = None
        self.stages = []  # (seconds since the job was seen, status, step)

    def s1(self):
        """A question about the README streams deltas and a tool step, then ends in a turn."""
        mark = self.o.mark()
        status, answer = self.o.say(
            f"Read the README of {REPO} and tell me in one sentence what it says. "
            f"Also remember the codeword {CODEWORD} for later."
        )
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        self.conv1 = answer.get("conversation")
        check(self.conv1, "the answer has no conversation")
        text = answer_text(answer)
        check("plan loop answered" not in text, f"the harness fell back: {text[-200:]}")
        check(oby_turn(self.o, mark, self.conv1), "no turn event from Oby")
        check(re.search(r"(?i)fixture|end-to-end|nothing here is real", text), f"the answer doesn't say what the README says: {text[:300]}")
        if not self.harness:
            raise Skip("no conversation harness on this branch (plan loop): no delta or tool steps to expect")
        check(conv_events(self.o, mark, self.conv1, "delta"), "no delta event")
        tools = [s for s in conv_events(self.o, mark, self.conv1, "step") if s.get("tool")]
        check(tools, "no step event with a tool")

    def s2(self):
        """A follow-up uses context from the first turn."""
        if not self.conv1:
            raise Skip("scenario 1 made no conversation")
        status, answer = self.o.say("What codeword did I ask you to remember earlier?", self.conv1)
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        check(answer.get("conversation") == self.conv1, "the follow-up joined another conversation")
        check(CODEWORD.lower() in answer_text(answer).lower(), f"no {CODEWORD} in: {answer_text(answer)[:300]}")

    def s3(self):
        """A job in bypass mode becomes a confirm inbox item, and no job starts."""
        mark = self.o.mark()
        status, answer = self.o.say(
            f"Start a job in {REPO} in bypass mode: add a multiply(a, b) function in src/multiply.js."
        )
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        conv = answer.get("conversation")
        time.sleep(5)
        jobs = [d for _, n, d in self.o.since(mark) if n == "job" and isinstance(d, dict)
                and (d.get("conversation") == conv or "multiply" in (d.get("task") or "").lower())]
        check(not jobs and not answer.get("jobs"), f"a job started: {[j.get('id') for j in jobs] or answer.get('jobs')}")
        s, _, inbox = self.o.request("GET", "/v1/inbox")
        items = inbox if isinstance(inbox, list) else (inbox or {}).get("items", []) if isinstance(inbox, dict) else []
        confirms = [i for i in items if i.get("kind") == "confirm" or i.get("ownersOnly")]
        check(confirms, f"no confirm item in the inbox ({s}): {[i.get('kind') for i in items]}")

    def s4_start(self):
        """A normal job starts with `conversation` set, and its card is on the turn."""
        mark = self.o.mark()
        status, answer = self.o.say(
            f"Start a job in {REPO}: add a subtract(a, b) function in src/subtract.js and a test for it "
            "in test/subtract.test.js, in the style of average.js. Keep it small."
        )
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        self.job_conv = conv = answer.get("conversation")
        ids = [j.get("id") if isinstance(j, dict) else j for j in answer.get("jobs") or []]
        if not ids:
            seen = self.o.wait_for(lambda e: e[1] == "job" and isinstance(e[2], dict) and e[2].get("conversation") == conv, 10, mark)
            check(seen, f"no job started: {answer_text(answer)[:300]}")
            ids = [seen[2]["id"]]
        self.job = ids[0]
        job = self.o.request("GET", f"/v1/jobs/{self.job}")[2]
        check(isinstance(job, dict) and job.get("conversation") == conv, f"the job's conversation is {job.get('conversation') if isinstance(job, dict) else job}, not {conv}")
        turn = self.o.wait_for(lambda e: e[1] == "turn" and isinstance(e[2], dict) and e[2].get("conversation") == conv
                               and e[2].get("who") == "oby" and self.job in [j.get("id") if isinstance(j, dict) else j for j in e[2].get("jobs") or []], 10, mark)
        check(turn, "the job's card isn't on Oby's turn (no turn event with its id in jobs)")

    def s4_wait(self):
        """The job ends done or failed within the timeout; each stage is timed."""
        if not self.job:
            raise Skip("scenario 4 started no job")
        last, t_first = None, None
        deadline = time.monotonic() + self.job_timeout
        i = 0
        while time.monotonic() < deadline:
            evs = self.o.since(i)
            i += len(evs)
            for t, n, d in evs:
                if n != "job" or not isinstance(d, dict) or d.get("id") != self.job:
                    continue
                t_first = t if t_first is None else t_first
                key = (d.get("status"), d.get("step"))
                if key != last:
                    self.stages.append((t - t_first, *key))
                    last = key
                if d.get("status") in TERMINAL and d.get("publishStep") is None:
                    self.job_ended = d
            if self.job_ended:
                break
            time.sleep(1)
        check(self.job_ended, f"the job hadn't ended after {self.job_timeout} s (last: {last})")
        status = self.job_ended.get("status")
        check(status in ("done", "failed"), f"the job ended {status}: {self.job_ended.get('summary', '')[:300]}")
        check(status == "done", f"the job failed: {self.job_ended.get('step')}: {self.job_ended.get('summary', '')[:300]}")

    def s5(self):
        """A write outside the room is refused."""
        target = os.path.join(self.o.run, "outside", "escape.txt")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        mark = self.o.mark()
        status, answer = self.o.say(f"Run this shell command and tell me what it printed: echo escaped > {target} && cat {target}")
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        check(not os.path.exists(target), f"{target} was written")
        steps = [s for s in conv_events(self.o, mark, answer.get("conversation"), "step") if s.get("tool")]
        if self.harness:
            tried = [s for s in steps if s.get("tool") in ("write", "bash")]
            check(not tried or any(s.get("state") == "failed" for s in tried), f"a write/bash step went through: {tried}")
            return "obid refused the agent's try" if tried else "the agent declined by itself; obid's rule wasn't exercised"

    def s6(self):
        """Telling the finished job "also add a test" picks it up again (#644)."""
        if not self.job_ended:
            raise Skip("scenario 4's job didn't end")
        mark = self.o.mark()
        status, answer = self.o.say(f"Tell job {self.job} to also add a test for subtract with negative numbers.", self.job_conv)
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        picked = self.o.wait_for(lambda e: e[1] == "job" and isinstance(e[2], dict) and e[2].get("id") == self.job
                                 and e[2].get("status") in ("queued", "running"), 120, mark)
        check(picked, f"the job didn't pick up again in 120 s: {answer_text(answer)[:300]}")
        ended = self.o.wait_for(lambda e: e[1] == "job" and isinstance(e[2], dict) and e[2].get("id") == self.job
                                and e[2].get("status") in TERMINAL and e[2].get("publishStep") is None,
                                self.job_timeout, mark + self.o.since(mark).index(picked) + 1)
        check(ended, f"its new round hadn't ended after {self.job_timeout} s")
        check(ended[2].get("status") == "done", f"its new round ended {ended[2].get('status')}: {ended[2].get('step')}")

    def s7(self):
        """An artifact: an `artifact` event, and its files served with a Content-Security-Policy."""
        if self.o.request("GET", "/v1/artifacts")[0] == 404:
            raise Skip("no artifacts on this branch")
        mark = self.o.mark()
        status, answer = self.o.say(f"Make me a small HTML page showing {REPO}'s functions as an artifact.")
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        conv = answer.get("conversation")
        arts = [d for _, n, d in self.o.since(mark) if n == "artifact" and isinstance(d, dict) and d.get("conversation") == conv]
        jobs = [j.get("id") if isinstance(j, dict) else j for j in answer.get("jobs") or []]
        for job in jobs:  # a job's artifacts (its .obi/artifacts/) publish when it ends
            self.o.wait_for(lambda e: e[1] == "job" and isinstance(e[2], dict) and e[2].get("id") == job
                            and e[2].get("status") in TERMINAL and e[2].get("publishStep") is None, self.job_timeout, mark)
            time.sleep(3)
        arts = [d for _, n, d in self.o.since(mark) if n == "artifact" and isinstance(d, dict)
                and (d.get("conversation") == conv or d.get("job") in jobs)]
        check(arts, f"no artifact event{' after its job ' + ', '.join(jobs) + ' ended' if jobs else ''}: {answer_text(answer)[:300]}")
        a = arts[-1]
        s, headers, meta = self.o.request("GET", f"/v1/artifacts/{a['id']}")
        check(s == 200, f"GET /v1/artifacts/{a['id']} answered {s}")
        s, headers, _ = self.o.request("GET", f"/v1/artifacts/{a['id']}/{a.get('version', 1)}/index.html")
        check(s == 200, f"its index.html answered {s}")
        csp = {k.lower(): v for k, v in headers.items()}.get("content-security-policy", "")
        check("default-src" in csp and "sandbox" in csp, f"no Content-Security-Policy with default-src and sandbox: {csp!r}")

    def s8(self):
        """An attached PNG: Oby says what's in it."""
        folder = os.path.join(self.o.home, "attachments")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "red-square.png")
        with open(path, "wb") as f:
            f.write(red_png())
        status, answer = self.o.say("What's in the image I attached? Name its main color in one word.", attachments=[path], new=True)
        if status in (400, 422) and "attach" in json.dumps(answer).lower():
            raise Skip(f"attachments refused ({status}): {answer}")
        check(status == 200, f"POST /v1/plans answered {status}: {answer}")
        check(re.search(r"(?i)\bred\b", answer_text(answer)), f"the answer doesn't say red: {answer_text(answer)[:300]}")


def red_png(size=16):
    """A solid red PNG, made with zlib alone."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\x00" + b"\xff\x00\x00" * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


# Run order: the job starts early and runs while the other scenarios talk.
ORDER = [("1", "s1"), ("2", "s2"), ("3", "s3"), ("4", "s4_start"), ("5", "s5"), ("7", "s7"), ("8", "s8"),
         ("4", "s4_wait"), ("6", "s6")]
NAMES = {"0": "obid starts", "1": "README question streams", "2": "follow-up keeps context", "3": "bypass becomes a confirm",
         "4": "job from talk, ends", "5": "write outside the room refused", "6": "tell finished job (#644)",
         "7": "artifact with CSP", "8": "attached PNG"}


def load():
    return " ".join(f"{x:.0f}" for x in os.getloadavg()) + f" on {os.cpu_count()} cores"


def compact(events, secrets, limit=4000):
    """Events as lines, consecutive deltas joined, tokens redacted."""
    lines, deltas = [], []
    def flush():
        if deltas:
            lines.append(f"  delta x{len(deltas)}: {''.join(deltas)[:300]!r}")
            deltas.clear()
    for t, n, d in events:
        if n == "delta" and isinstance(d, dict):
            deltas.append(d.get("text", ""))
            continue
        flush()
        if n == "job" and isinstance(d, dict):
            d = {k: d.get(k) for k in ("id", "status", "step", "conversation", "summary", "publishError") if d.get(k) is not None}
        lines.append(f"  {t:7.1f}s {n}: {json.dumps(d)[:600]}")
    flush()
    return redact("\n".join(lines), secrets)[-limit:]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--obid", required=True, help="the obid binary to test")
    ap.add_argument("--label", default="", help="a name for this run in the output (a branch, a sha)")
    ap.add_argument("--only", default="", help="scenario numbers to run, e.g. 1,2,7 (4 and 6 need 4)")
    ap.add_argument("--job-timeout", type=int, default=900, help="seconds scenario 4's job may take (900)")
    ap.add_argument("--account-dir", default=ACCOUNT_DIR, help="the Claude account's configDir")
    ap.add_argument("--remote", default=REMOTE, help=f"{REPO}'s remote")
    ap.add_argument("--json", help="also write the results to this file")
    ap.add_argument("--keep", action="store_true", help="keep the run folder (it holds the API token)")
    args = ap.parse_args()

    binary = os.path.abspath(args.obid)
    has_harness = b"plan loop answered" in open(binary, "rb").read()
    only = set(filter(None, args.only.split(",")))
    run_dir = tempfile.mkdtemp(prefix="obi-live-")
    os.chmod(run_dir, 0o700)
    results, timings = {}, []
    o = None
    try:
        o = Obid(binary, run_dir, args.account_dir, args.remote)
        print(f"obid {args.label} on 127.0.0.1:{o.port}, harness {'yes' if has_harness else 'no'}, run {run_dir}, "
              f"load {load()}", flush=True)
        suite = Suite(o, has_harness, args.job_timeout)
        mark = o.mark()
        for num, fn in ORDER:
            if only and num not in only:
                continue
            if results.get(num, {}).get("result") in ("fail", "skip") and fn == "s4_wait":
                continue
            t = time.monotonic()
            try:
                res, why = "pass", getattr(suite, fn)() or ""
            except Skip as e:
                res, why = "skip", str(e)
            except Fail as e:
                res, why = "fail", str(e)
            except Exception as e:  # a crash in the harness or obid is the scenario's failure
                res, why = "fail", f"{type(e).__name__}: {e}"
            took = time.monotonic() - t
            prev = results.get(num)
            took += prev["seconds"] if prev else 0
            end = o.mark()  # windows touch: no event falls between two scenarios
            events = (prev["events"] if prev else []) + o.since(mark)[: end - mark]
            mark = end
            results[num] = {"result": res, "why": why, "seconds": round(took), "events": events}
            print(f"  {num} {fn:8} {res:4} {took:6.0f}s {redact(why, [o.token])[:200]}", flush=True)
        timings = suite.stages
    except Exception as e:
        print(f"the run broke: {e}", flush=True)
        results.setdefault("0", {"result": "fail", "why": str(e), "seconds": 0, "events": []})
    finally:
        secrets = [o.token] if o else []
        if o:
            time.sleep(3)  # the last job's cleanup (keep_commits) runs just after its done event
            o.stop()
            failed = any(r["result"] == "fail" for r in results.values())
            log_tail = redact(o.tail(), secrets) if failed else ""
            if failed and args.json:
                with open(o.log_path, errors="replace") as f, open(args.json + ".obid.log", "w") as out:
                    out.write(redact(f.read(), secrets))
        if not args.keep:
            rmtree(run_dir)

    print(f"\n{'#':<3}{'scenario':<34}{'result':<8}{'time':>6}  why")
    for num in sorted(results):
        r = results[num]
        print(f"{num:<3}{NAMES.get(num, num):<34}{r['result']:<8}{r['seconds']:>5}s  {redact(r['why'], secrets)[:160]}")
    if timings:
        print(f"\nscenario 4, the job's stages (from its first event; load now {load()}, so times under load aren't representative):")
        for i, (t, status, step) in enumerate(timings):
            end = timings[i + 1][0] if i + 1 < len(timings) else t
            print(f"  {t:7.1f}s +{end - t:6.1f}s  {status:<11} {redact(str(step), secrets)[:100]}")
    for num in sorted(results):
        r = results[num]
        if r["result"] == "fail":
            print(f"\n--- {num} {NAMES.get(num, num)} failed: {redact(r['why'], secrets)}")
            print(compact(r["events"], secrets))
    if o and log_tail:
        print(f"\n--- obid log (tail)\n{log_tail}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"label": args.label, "harness": has_harness, "stages": timings, "load": load(),
                       "results": {k: {**v, "events": json.loads(redact(json.dumps(v["events"]), secrets))}
                                   for k, v in results.items()}}, f, indent=1)
    return 1 if any(r["result"] == "fail" for r in results.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
