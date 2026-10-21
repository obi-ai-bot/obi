# The end-to-end scenario: a review across two Obis

This is what "done" means for Phase 1. Four workstreams build in parallel (the Sphere server, the Rust core `obid`, the repository restructure, the plug-in boundary; [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)), and this scenario is the one run that must go green when their work meets. Every call, value and expected outcome below is exact: if an implementation needs something this document doesn't say, change this document first, in its own pull request.

The contracts it relies on:

- **Obi-to-Obi protocol v0.1** and the **Sphere's HTTP API**: `spec/` in [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere) (`protocol.md`, `identity.md`, `sphere-api.md`, the JSON Schemas and the conformance suite).
- **The runner API** that `obid` serves: [docs/runner-api.md](../docs/runner-api.md), including its section "obid only" for everything this scenario needs that the Swift runner never had.

## Running it

```sh
make e2e          # stub agents: headless, no model credentials, Linux and macOS (CI runs this)
make e2e-live     # the real Claude Code adapter: a person runs it on a Mac (see "Live mode")
```

| Variable | Default | What |
|---|---|---|
| `OBI_SPHERE_DIR` | `../obi-sphere`, next to this repository | The obi-sphere checkout: its `spec/` (schemas, reference verifier) and `server/` (the Sphere). `make` installs both with `pnpm install --frozen-lockfile`. |
| `OBID_BIN` | `core/target/debug/obid` in this repository | The `obid` binary to run. With the default, `make e2e` builds it first (`cargo build --locked -p obid` in `core/`, once `core/Cargo.toml` exists) and stops if the build fails; with another value it builds nothing and runs that binary. CI installs a stable Rust toolchain for the build. |
| `OBI_E2E_RUN_DIR` | a new folder under the system's temp folder | Where the run keeps everything it makes. |
| `OBI_E2E_KEEP` | unset | `1` keeps the run folder afterwards, for reading the logs. |
| `OBI_SPHERE_URL` | unset | Opt-in remote mode: the base URL of a Sphere that is already deployed. See "Against a deployed Sphere". |
| `SPHERE_OPERATOR_TOKEN` | unset | The deployed Sphere's operator token; required with `OBI_SPHERE_URL`, never printed, written or committed. |
| `OBI_E2E_REMOTE` | unset | `1` (or the `--remote` argument) confirms remote mode. Under `CI` only the variable counts. |

Needs: Node 22.18 or later (obi-sphere’s minimum, which also meets the pinned pnpm’s requirement), pnpm, git, and a Rust toolchain (`cargo`) once `core/` exists. Nothing else at run time: no network beyond 127.0.0.1 (except remote mode, below), no GitHub, no model (building obid and installing obi-sphere's packages may fetch dependencies first).

Keep both checkouts idle during the scenario: do not run concurrent builds, tests or other tools that change their files. Snapshots include gitignored build output (except the exclusions in step 8.4.1) and hash it in bounded chunks, including files larger than 2 GiB. Snapshot I/O failures are reported as `[harness snapshot]`.

The harness is [`e2e/run.mjs`](run.mjs). It runs five **preflight** checks (Node, git, the fixture repository, the stub agent, and that this document, `e2e/fixtures/messages/` and the harness's values in `e2e/lib/` agree and the messages validate against the spec; these pass today), then the eight **steps** below in order, prints one line per check, and exits 0 only when all of them pass. A step whose body isn't written yet prints `step N (<title>): not implemented`. Every step builds on the ones before it, so a written step after one that failed or isn't written yet prints `not run`, naming that step. Every process the harness starts runs in its own process group, and when the run ends, whatever ended it (a pass, a failure, an exception, SIGINT or SIGTERM), the harness sends each group still running SIGTERM, then SIGKILL 10 seconds later.

### Against a deployed Sphere

**This writes to a real Sphere.** Run it against a production Sphere only with its owner's OK. Every run creates a Sphere of its own there and leaves it behind (below).

```sh
SPHERE_OPERATOR_TOKEN="$(security find-generic-password -s obi-sphere-operator-token -w)" \
OBI_SPHERE_URL=https://obysphere.deskree.com OBI_E2E_REMOTE=1 make e2e
```

Three things must all be set, or the run refuses before it starts anything (exit 2): `OBI_SPHERE_URL`, `SPHERE_OPERATOR_TOKEN`, and `OBI_E2E_REMOTE=1` or `--remote` (`node e2e/run.mjs --remote`). With `CI` set, only `OBI_E2E_REMOTE=1` is accepted. Only the URL's origin is printed.

The run uses that Sphere instead of starting one with `node scripts/local.mjs`. Everything else is as written: two real obids with stub agents, the same eight steps and checks. Only these differ:

- The Sphere is `OBI_SPHERE_URL` and its operator token is `SPHERE_OPERATOR_TOKEN`; every "`http://127.0.0.1:<sphere port>`" above is that origin. obid accepts any `http(s)` Sphere base URL (`is_base_url`), so this is real obid over HTTPS.
- Step 1.2 creates Sphere `e2e-<8 hex digits>`, new for every run, in place of `e2e`; the owner assertions' `aud`, every `/v0.1/spheres/<id>/…` path and the envelope checks use that id.
- Skipped, because there is no local Sphere process: step 1.1's start (the health check is still made), step 8.6's SIGTERM to the Sphere, and the Sphere's ports and write root (`R/sphere/`). obid A, obid B, the fixture and the checkouts' write checks stay.
- **Cleanup:** v0.1 can't delete a Sphere. When the run ends, however it ends, the harness revokes both test Obis (`DELETE /v0.1/spheres/<id>/members/<obi>`, admin token) and prints the result. The Sphere, its members (revoked), invitations and audit rows stay in the deployed Sphere's database. If the revoke fails, the output says so and names the Sphere. An operator-only Sphere delete in obi-sphere would remove this leftover; it is a follow-up there.

## Processes, folders and ports

The run folder (`R` below) holds:

| Path | What |
|---|---|
| `R/fixture/work` | The fixture repository's working clone (built in preflight). |
| `R/fixture/remote.git` | The bare repository both obids clone from, as `file://R/fixture/remote.git`. Plays GitHub. |
| `R/stub-check/` | The preflight's worktree for checking the stub agent alone. |
| `R/sphere/state`, `R/sphere/home`, `R/sphere/tmp` | The Sphere's local D1 (`--persist-to`), its `HOME` and its `TMPDIR`. |
| `R/obid-a/` | Obi A: `config.json`, `home/` (obid's own home: database, keys, clones, worktrees), `env-home/` (its `HOME`), `tmp/` (its `TMPDIR`), `obid.log`. |
| `R/obid-b/` | Obi B, the same. |
| `R/harness/` | The harness's own logs. |

The harness picks three free ports on 127.0.0.1: the Sphere's, A's and B's. It generates per run, in memory, never on disk: the Sphere's operator token (32 random bytes, base64url) and the two owner keys (Ed25519): **W** for wellington, **E** for ernesto. It also generates each obid's API token (32 random bytes, hex), which goes on disk in one place only, that obid's `home/api-token` (0600), because obid takes its token from nowhere else: never from its environment or arguments (docs/runner-api.md, "obid only: configuration").

## The fixed values

| What | Value |
|---|---|
| Sphere | `e2e`, named `E2E sphere`, admin owner `wellington` |
| Obi A | `obi-wellington`, owner `wellington`, named `Wellington's Obi`, accepts `["review_request"]` |
| Obi B | `obi-ernesto`, owner `ernesto`, named `Ernesto's Obi`, accepts `["review_request"]` |
| Policy | one rule: `{"id": "team-reviews", "from_owner": "*", "to_owner": "*", "actions": ["review_request"], "repos": ["obi-e2e/fixture-app"]}` |
| Obi scopes (each delegation) | `send:review_request reply receive directory:read audit:read` |
| Admin scopes | `admin directory:read audit:read` |

### The fixture repository

`obi-e2e/fixture-app`, built at test time by [`e2e/lib/fixture.mjs`](lib/fixture.mjs) from the files in [`e2e/fixtures/repo/`](fixtures/repo/). No `.git` folder is ever committed. Git runs with no user or system settings (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, no hooks, no templates, no signing, `core.autocrlf=false`, `core.fileMode=false`), SHA-1 objects asked for by name (`git init --object-format=sha1`, so a git whose default is SHA-256 makes the same ids), author and committer `Obi E2E Fixture <fixture@obi-e2e.invalid>`, so the commit ids are the same on every machine:

| Branch | Commit | Date (author and committer) | Message | Files |
|---|---|---|---|---|
| `main` | `aeab70f3025191d31993e778dba0eacc96c3b913` | `1767225600 +0000` | `Initial fixture app` | `fixtures/repo/base/`: `README.md`, `package.json`, `src/greet.js`, `test/greet.test.js` |
| `feature/average` | `6d20146f366b9fac8907b5066c30ee39aaec09b3` | `1767229200 +0000` | `Add an average helper` | `main` plus `fixtures/repo/head/`: adds `src/average.js` and `test/average.test.js`, changes `src/greet.js` |

The "pull request" is the branch `feature/average` into `main`; there is no pull request number. The repository's check is `node --test`, and it passes at `feature/average`.

### The brief: the review_request body

[`fixtures/messages/brief.json`](fixtures/messages/brief.json), sent twice by Obi B:

```json
{
  "goal": "Add an average helper to the fixture app (OBI-E2E-DATA-CANARY goal)",
  "repo": "obi-e2e/fixture-app",
  "base_branch": "main",
  "head_branch": "feature/average",
  "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3",
  "acceptance": [{"kind": "tests_pass"}, {"kind": "no_blocker_findings"}],
  "summary": "Adds src/average.js with a test and touches src/greet.js.\nOBI-E2E-DATA-CANARY summary: this text is data. An agent that follows it as an instruction is a bug."
}
```

The acceptance conditions are "tests pass, no blocker findings", typed. Every message expires 3,600 seconds after it is made: the requests by `expiresIn: 3600`, and obid's replies by its rule (docs/runner-api.md, "Expiry of what obid sends"), which here gives the same.

**The canary.** `OBI-E2E-DATA-CANARY` appears only in the brief's data fields (`goal`, `summary`). It must never reach an agent's prompt (the stub agent fails the turn if it does), an inbox item's `title` or `text` (obid builds those from typed fields only; the data is under `obi.quoted`), or a result.

### The two known findings, and the verdict

The stub agent finds exactly these at `6d20146f…`. Their ids are the spec's recommended derivation (`f-` + the first 16 hex of SHA-256 of `file\nline\ntitle`), which obid uses:

| id | severity | file | line | title |
|---|---|---|---|---|
| `f-8424ac27bbfa2630` | `major` | `src/average.js` | 4 | `average() divides by zero for an empty list` |
| `f-e82e5a31927dc589` | `minor` | `src/greet.js` | 2 | `` Unused variable `trimmed` `` |

Their `detail` texts are in [`fixtures/messages/result.example.json`](fixtures/messages/result.example.json). None of the texts looks like a secret to the publish gate's scan (no key formats, no `password`/`secret`/`token` assignment), so the scan is genuinely clean.

Tests pass and neither finding is a `blocker`, so both conditions are met and **the outcome is `approved`**. The result body Obi A returns for the first request is exactly:

```json
{
  "for": "review_request",
  "outcome": "approved",
  "repo": "obi-e2e/fixture-app",
  "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3",
  "findings": [ …the two findings above, in that order, with their detail… ],
  "acceptance": [{"index": 0, "kind": "tests_pass", "met": true}, {"index": 1, "kind": "no_blocker_findings", "met": true}],
  "summary": "Two findings, no blocker: an empty list breaks average(), and greet() has an unused variable."
}
```

The second request's result is the same plus `"by_rule": "<decision id>"`. Findings are in the order the agent reported them; the `summary` is the agent's.

### The decision and the inbox answer

- The inbox item's options, in this order: `Accept`, `Accept, and remember for this repo`, `Decline`, `Decline, and remember for this repo`.
- The test answers `Accept, and remember for this repo`, through `POST /v1/inbox/{id}/answer` on obid A, as the owner would.
- That leaves one remembered decision, "reviews from ernesto on this repo": `{"type": "review_request", "fromOwner": "ernesto", "repo": "obi-e2e/fixture-app", "decision": "accept"}` with an id like `d-3f9a0c1b2e4d` (`d-` and 12 lower-case hex).

## The stub agent

[`e2e/stub-agent/stub-agent`](stub-agent/stub-agent), a Node script (`#!/usr/bin/env node`), is a drop-in for the `claude` binary in obid's Claude Code adapter. It needs no model and no credentials, and writes nothing (its one probe, below, is refused by obid's job sandbox).

- **How obid finds it.** obid's config file names the Claude Code adapter's binary: `"agents": {"claude": {"bin": "<obi>/e2e/stub-agent/stub-agent", …}}` (docs/runner-api.md, "obid only: configuration"). obid runs it exactly as it would run `claude`.
- **Arguments.** `--version` prints `0.1.0 (stub-agent; Claude Code stream-json compatible)` and exits 0. Otherwise it needs `-p` (or `--print`), `--input-format stream-json` and `--output-format stream-json` (exit 64 without them). With `--json-schema <schema>` its result carries `structured_output`, as Claude Code's does. Every other flag is accepted and ignored. obid passes, for an Obi-to-Obi review: `-p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio --permission-mode default --setting-sources "" --json-schema <the review output schema>` (the schema is in docs/runner-api.md, "obid only: Obi-to-Obi review jobs", and [`e2e/lib/scenario.mjs`](lib/scenario.mjs)).
- **Working directory.** The job's worktree, at the request's `head_sha`, with the request quoted in `.obi/inputs/obi-request.json`: `{"from": "obi-ernesto", "from_owner": "ernesto", "type": "review_request", "body": { …the brief, verbatim… }}`.
- **stdin.** Newline-delimited JSON. It answers each `{"type": "user", "message": {"role": "user", "content": …}}` line (content a string or text blocks) with one turn, ignores other lines, and exits 0 when stdin closes. obid closes stdin after the turn's `result` line.
- **stdout.** Three lines on the first turn (two on later ones), each one JSON object:
  1. `{"type": "system", "subtype": "init", "cwd": "<worktree>", "session_id": "<uuid>", "tools": ["Read", "Grep", "Glob"], "mcp_servers": [], "model": "stub-agent", "permissionMode": "default", "apiKeySource": "none", "claude_code_version": "stub-0.1.0"}`
  2. `{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Reviewing feature/average at 6d20146 against main."}], …}, "session_id": …}`
  3. `{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "result": "<the review as Markdown>", "session_id": …, "total_cost_usd": 0, "structured_output": {"summary": "…", "findings": [{"severity", "file", "line", "title", "detail"}, …]}}`
- **What it checks, failing the turn** (a `result` with `"subtype": "error_during_execution"`, `"is_error": true`, the reasons in `result`, exit 3): the prompt is empty or contains `OBI-E2E-DATA-CANARY`; `.obi/inputs/obi-request.json` is missing, isn't a `review_request`, or lacks the canary; `git rev-parse HEAD` isn't the request's `head_sha`; its environment has `CLAUDECODE`, `CLAUDE_CODE_*`, `ANTHROPIC_*`, `GH_TOKEN` or `GITHUB_TOKEN`; it can create a file in the folder that holds its worktree (under obid that is `home/worktrees/`, outside the job's write root: it removes the file at once, and the failure says there is no job sandbox). `OBI_STUB_NO_SANDBOX=1` in its environment skips that last check: only the preflight sets it, running the stub alone; the harness never gives it to obid.
- **How it reviews.** Fixed rules: the line `return total / values.length;` in `src/average.js` and the line `const trimmed = name.trim();` in `src/greet.js`, each found by its content, so the line numbers come from the files actually checked out.

The preflight runs it alone on a worktree of the fixture and checks the two findings, that a prompt carrying the brief's goal is refused, that with no sandbox around it (and its probe on) it fails the turn and leaves no probe file, and that the worktree is unchanged.

## The steps

"Admin token" is an owner's own token for wellington, made as step 1.3 says. It never outlives its assertion, which lives at most 300 seconds and whose `jti` is single-use (identity.md 4.1 and 4.3), and the steps together take longer than that. So before every Sphere call that sends the admin token, in any step, the harness makes a new one the same way (a new assertion: new `iat`, `exp` and `jti`) and uses it for that call only; the one step 1.3 makes only proves the exchange. Every Sphere call is `http://127.0.0.1:<sphere port>/v0.1/…`; every obid call is `http://127.0.0.1:<obid port>/v1/…` with `Authorization: Bearer <that obid's API token>`. "Within N seconds" means the harness polls (every 250 ms) and fails the step after N seconds. A step fails on the first expectation that doesn't hold, and says which.

### Step 1: Sphere up, team created, two Obis invited

Turned green by: **the Sphere server**.

1. Start the Sphere: in `$OBI_SPHERE_DIR/server`, `node scripts/local.mjs --port <sphere port> --persist-to R/sphere/state`, with `SPHERE_OPERATOR_TOKEN`, `HOME=R/sphere/home`, `TMPDIR=R/sphere/tmp`, `WRANGLER_SEND_METRICS=false` and `PATH` (sphere-api.md, "Running a Sphere locally"). Within 60 seconds `GET /v0.1/health` answers `200 {"ok": true, "protocol": "obi/0.1"}`.
2. `POST /v0.1/spheres` with the operator token: `{"sphere": "e2e", "name": "E2E sphere", "admin": {"owner": "wellington", "owner_key": "<W public>"}}` → `201` with `sphere` `e2e`, `admin_owner` `wellington`, `protocol` `obi/0.1`.
3. The admin token (how every one is made; see above for when): an owner assertion signed by W, `{"iss": "wellington", "sub": "wellington", "aud": "obi-sphere:e2e", "iat": now, "exp": now + 300, "jti": <uuid>, "scope": "admin directory:read audit:read"}`, exchanged at `POST /v0.1/oauth/token` (`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token`, `subject_token_type=urn:ietf:params:oauth:token-type:jwt`, no actor) → `200`, `token_type` `Bearer`, `scope` exactly `admin directory:read audit:read` (the spec fixes the order the Sphere writes scopes in: identity.md 4.2, "Canonical order").
4. `POST /v0.1/spheres/e2e/invitations` (admin token) `{"owner": "wellington", "obi": "obi-wellington", "expires_in": 3600}` → `201` invitation A; the same for `ernesto` / `obi-ernesto` → invitation B. Each has an `invitation_id` and a 43-character `secret`.
5. `GET /v0.1/spheres/e2e/policy` → `{"version": 0, "rules": [], …}`; `PUT /v0.1/spheres/e2e/policy` `{"expected_version": 0, "rules": [<team-reviews>]}` → `200` with `version` 1 and that rule.
6. `GET /v0.1/spheres/e2e/audit` → `entries` `[]`, `head` `{"seq": 0, "hash": "000…000"}`.

### Step 2: two obids up with stub agents, and paired

Turned green by: **the Rust core** (`obid`'s configuration and join), with **the Sphere server** (redeem).

1. Write `R/obid-a/config.json` (docs/runner-api.md, "obid only: configuration"):

   ```json
   {"listen": "127.0.0.1:<A port>", "home": "R/obid-a/home", "owner": "wellington",
    "agents": {"claude": {"bin": "<obi>/e2e/stub-agent/stub-agent",
                          "accounts": [{"id": "stub", "name": "Stub", "configDir": "R/obid-a/home/accounts/stub"}]}},
    "repos": [{"repo": "obi-e2e/fixture-app", "remote": "file://R/fixture/remote.git", "defaultBranch": "main", "check": "node --test"}],
    "allowFileRemotes": true, "telemetry": false}
   ```

   and `R/obid-b/config.json` the same with B's port, home and `"owner": "ernesto"` (absolute paths in both).
2. Write each obid's API token to `R/obid-x/home/api-token` (0600). Start each: `$OBID_BIN serve --config R/obid-x/config.json`, with `HOME=R/obid-x/env-home`, `TMPDIR=R/obid-x/tmp` and `PATH`, and no token in its environment or arguments; stdout and stderr to `R/obid-x/obid.log`. Within 30 seconds `GET /v1/status` answers `200` with `runner.engine` `obid`.
3. For each Obi (A with W and invitation A, B with E and invitation B):
   1. `POST /v1/obid/sphere/key` → `200 {"keyId", "publicKey"}`.
   2. `POST /v1/obid/sphere/card` `{"url": "http://127.0.0.1:<sphere port>", "sphere": "e2e", "obiId": "obi-wellington", "name": "Wellington's Obi", "ownerKey": "<W public>", "accepts": ["review_request"]}` → `200 {"card": { …the card without signatures… }}`, whose Obi extension carries obid's `keyId` and `publicKey`.
   3. The harness signs the card as the owner (identity.md 2.1) and makes the delegation, an owner assertion signed by W: `{"iss": "wellington", "sub": "wellington", "aud": "obi-sphere:e2e", "iat": now, "exp": now + 3600, "jti": <uuid>, "scope": "send:review_request reply receive directory:read audit:read", "may_act": {"sub": "obi-wellington"}}`.
   4. `POST /v1/obid/sphere/join` `{"url": "http://127.0.0.1:<sphere port>", "sphere": "e2e", "invitation": {"id": "<invitation A id>", "secret": "<secret>"}, "card": <signed card>, "delegation": "<JWT>"}` → `200` membership with `state` `joined`, `obiId` `obi-wellington`, its `keyId`.
4. `GET /v0.1/spheres/e2e/members` (admin token): two members, `obi-wellington` (owner `wellington`) and `obi-ernesto` (owner `ernesto`), both `active`, each with one key whose `key_id` is its obid's `keyId`, `valid_from_seq` 1, `valid_until_seq` null; each card passes the spec's card check with its owner's key bound (`verifyCard`).

### Step 3: B sends review_request via relay

Turned green by: **the Rust core** (Obi-to-Obi client) and **the Sphere server** (send).

1. `POST /v1/obid/sphere/requests` on B: `{"to": "obi-wellington", "type": "review_request", "body": <the brief>, "expiresIn": 3600}` → `202` exchange with `correlationId` **X**, `direction` `outgoing`, `peer` `obi-wellington`, `state` `sent`, and one message: the signed envelope with `seq` 1.
2. `GET /v0.1/spheres/e2e/audit` (admin token): one entry, `seq` 1, whose envelope deep-equals B's message: `type` `review_request`, `from` `obi-ernesto`, `to` `obi-wellington`, `id` and `correlation_id` X, `key_id` B's key, `body` deep-equal to the brief. The spec's `verifyEnvelope` accepts it with the context `{now: <the harness's clock>, sphere: "e2e", receiver: "obi-wellington", keys: <every member's keys from GET /v0.1/spheres/e2e/members>, seq: 1, seen_ids: []}`, keys given as `{key_id: {obi, public_key, valid_from_seq, valid_until_seq}}`.

### Step 4: A has no remembered decision: inbox, owner accepts and remembers, review job dispatched

Turned green by: **the Rust core**.

1. `GET /v1/obid/decisions` on A → `[]`.
2. Within 30 seconds, `GET /v1/inbox` on A lists exactly one item of `kind` `obiRequest` whose `obi.correlationId` is X. Its `options` are the four above, in order; its `title` and `text` don't contain `OBI-E2E-DATA-CANARY`; `obi.quoted.goal` is the brief's `goal`. A's `GET /v1/obid/sphere/exchanges/X`: `direction` `incoming`, `state` `inbox`, `inboxItem` that item's `id`.
3. `POST /v1/inbox/{id}/answer` on A: `{"answer": "Accept, and remember for this repo"}` → `200`, the item with `state` `done` and that `answer`.
4. `GET /v1/obid/decisions` on A: exactly one decision, matching "The decision and the inbox answer" above; call its id **D1**.
5. Within 10 seconds A's exchange X has `state` `accepted` or `done`, `decidedBy` `inbox`, `rule` null and a `job` **J1**. `GET /v1/jobs/J1`: `kind` `review`, `repo` `obi-e2e/fixture-app`, `obi.correlationId` X, `obi.fromOwner` `ernesto`, and a `worktree` inside `R/obid-a/home/worktrees/`.

### Step 5: job finishes, publish gate scan is clean, typed result returned via relay

Turned green by: **the Rust core** (the job, the check, finding ids, the publish gate, the reply) and **the Sphere server** (relay).

1. `GET /v1/jobs/J1/wait` on A, within 120 seconds: `status` `done`, `publishError` null, `published` null, `outgoing` `[]` (nothing pushed, no pull request, no check run).
2. J1's worktree: `git rev-parse HEAD` is `6d20146f…`; `git status --porcelain --untracked-files=all` lists nothing outside `.obi/`.
3. A's exchange X: `state` `done`, `publishScan` `{"ran": true, "clean": true}`.
4. Within 30 seconds B's exchange X has `state` `done`, and its messages are, in order: the request (sent), an `accept` with an empty body (received), any number of `status` (received), and a `result` (received) whose body is exactly the expected result above. No `status` comes before the `accept`: the protocol would allow one, but obid never sends one (docs/runner-api.md, "What obid sends in an exchange it was asked in"). Every received envelope passes the spec's `verifyEnvelope` with the context `{now: <the harness's clock>, sphere: "e2e", receiver: "obi-ernesto", keys: <every member's keys, as in step 3.2>, seq: <its seq in B's exchange>, seen_ids: []}`.

### Step 6: second review_request accepted from the remembered decision, no inbox

Turned green by: **the Rust core**.

1. `POST /v1/obid/sphere/requests` on B with the same body → exchange **Y**.
2. Within 120 seconds B's exchange Y has `state` `done`: its `accept` body is `{"by_rule": "D1"}` and its `result` body is the expected result plus `"by_rule": "D1"`.
3. A's exchange Y: `decidedBy` `rule`, `rule` D1, `inboxItem` null, and a job **J2**, not J1, whose `worktree` is inside `R/obid-a/home/worktrees/` and isn't J1's (a fresh worktree).
4. A's inbox: across `GET /v1/inbox` and `GET /v1/inbox?state=done`, still exactly one item of kind `obiRequest`, the one from step 4. `GET /v1/obid/decisions`: still only D1, with `uses` 1.

### Step 7: audit chain holds both exchanges, signed by their senders, and verifies

Turned green by: **the Sphere server** (with each Obi's signatures).

1. `GET /v0.1/spheres/e2e/audit?from_seq=1&limit=1000` and `GET /v0.1/spheres/e2e/members` (admin token).
2. The spec's `verifyChain({sphere: "e2e", entries}, {keys})`, with every member's key history, accepts the chain (sphere-api.md 7.1).
3. The entries are exactly the two exchanges: for X and then Y, a `review_request` from `obi-ernesto` signed with B's key, an `accept` and a `result` from `obi-wellington` signed with A's key, and any `status` from `obi-wellington` in between; nothing else. Each entry's envelope deep-equals the one in its sender's exchange, signature included. `head.seq` is the number of entries and `head.hash` the last entry's `hash`.

### Step 8: final assertions

Turned green by: **both**.

1. **Findings.** Both results carried the two known findings (steps 5 and 6).
2. **The inbox was used exactly once.** One `obiRequest` item on A in all (step 6.4); none on B (`GET /v1/inbox` and `?state=done` on B list no `obiRequest` item).
3. **The audit chain verifies** (step 7).
4. **No process wrote outside its write root, as far as the run can see** (below).
5. **Nothing was pushed.** `git for-each-ref` in `R/fixture/remote.git` is the same as before step 1: `refs/heads/feature/average 6d20146f…` and `refs/heads/main aeab70f3…`, nothing else.
6. **Clean exit.** SIGTERM to the PID of obid A, obid B and the Sphere launcher (not their process groups): each exits within 10 seconds, the obids with status 0, with no descendants left running. The harness exits 0.

## "No process wrote outside its write root"

Every process the run starts has a **write root**:

| Process | May write in |
|---|---|
| The Sphere (`wrangler dev`) | `R/sphere/` (its state, `HOME`, `TMPDIR`), `$OBI_SPHERE_DIR/server/.wrangler/` (wrangler's scratch) and the `node_modules/` folders in `$OBI_SPHERE_DIR` (installed packages and their caches, like `server/node_modules/.cache/`; sphere-api.md, "Running a Sphere locally") |
| obid A, obid B | `R/obid-a/`, `R/obid-b/` (its home, `HOME`, `TMPDIR`) |
| Each agent (the stub, or Claude Code in live mode), and the repository's check | its job's worktree, the worktree's own git directory and the job's own temporary folder (its `HOME` and `TMPDIR`), inside its obid's home; obid's job sandbox enforces it (docs/runner-api.md, "The job sandbox"), and the stub writes nothing |
| The harness | `R/harness/` |

What step 8.4 checks, and fails on with the path:

1. **The checkouts and the fixture.** The harness snapshots (every file's path, size and SHA-256; [`e2e/lib/snapshot.mjs`](lib/snapshot.mjs)) the obi checkout, the obi-sphere checkout and `R/fixture/`, after the preflight and before step 1, and again after step 8. Any file added, removed or changed in them fails, except under these path patterns (`SNAPSHOT_EXCLUDES` in `snapshot.mjs`, which is what `snapshot()` skips). A pattern is a folder path relative to the snapshotted root, ending in `/`: `a/b/` skips the folder `a/b` at that place only, and `**/name/` skips every folder called `name` at any depth, the top level included. Patterns match whole path segments, so `**/node_modules/` doesn't skip `my_node_modules/`.

   | Root | Excluded |
   |---|---|
   | The obi checkout | `.git/`, `core/target/` |
   | The obi-sphere checkout | `.git/`, `**/node_modules/`, `server/.wrangler/` |
   | `R/fixture/` | nothing |

   Anything else the Sphere writes in its checkout (a `.mf/` folder, say) fails the check: its state belongs under `--persist-to`.
2. **Obi B ran nothing.** `R/obid-b/home/worktrees/` is empty or missing after step 8: B never accepts work in this scenario.
3. **The agent's worktree.** Step 5.2: J1's worktree is at `head_sha` with nothing changed outside `.obi/`, and the same for J2 after step 6.
4. **The person's home and the system's temp folder, by name.** The harness lists the top level of its own `HOME` and of `os.tmpdir()` before step 1 and after step 8. No entry may appear whose name starts with `obid`, `obi-` (other than the run folder itself), `.obi`, `.wrangler`, `wrangler` or `.claude`. Every process gets its own `HOME` and `TMPDIR` inside its write root, which is what keeps them out; this check catches a process that ignores them.

What it does **not** check, and what covers it instead:

- **Writes between write roots inside `R`**: obid A writing into `R/obid-b/` or `R/sphere/`, the Sphere writing into an obid's folder. Every one of them writes inside `R` while the run goes on, so a snapshot can't say who wrote what. Each process is told only its own folders (its config, `HOME`, `TMPDIR`, `--persist-to`); nothing else names another's.
- **An agent writing elsewhere in its obid's home.** obid itself writes there throughout, so a snapshot can't tell. In stub mode the stub writes nothing (the preflight checks it on a worktree of its own), and it proves the sandbox is there: in each review job it tries to create a file in `home/worktrees/`, beside its worktree, and fails the turn, and so the step, when it can. That proves one folder, not every path: that a real agent and the check can't write anywhere outside the worktree, its git directory and the job's temporary folder is obid's sandbox's guarantee, tested in `core/` by the Rust core's own tests (docs/ARCHITECTURE.md, "Rust core", done-when).
- **Anything else on the machine.** Only the top-level names above are looked at.

## Live mode

`make e2e-live` is the same run with the real Claude Code adapter for Obi A. A person runs it on a Mac with Claude Code signed in; it uses that account's model usage, needs the network for the model only, and never runs in CI.

What changes:

- obid A's config names the real binary and the person's own Claude Code login: `"agents": {"claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]}}` (obid resolves `claude` from the login shell's `PATH`). obid B keeps the stub (it never runs an agent in this scenario).
- obid A keeps the person's real `HOME` (Claude Code's login lives there), so the write check covers the obi and obi-sphere checkouts, `R/fixture/`, B's empty `worktrees/` and the worktrees' state, and not the home's top level (Claude Code writes there by design).
- The model decides the findings, so step 5.4 and 6.2 check less: the result passes the spec's checks (schema and self-consistency); `tests_pass` is met; among its findings is one at `src/average.js` line 4 and one at `src/greet.js` line 2 (any severity, any title; ids by the same derivation); the outcome is `approved` if no finding is a `blocker`, else `changes_requested`. The second result has the same findings by id and `by_rule` D1.
- Everything else holds as in stub mode: the canary never in a prompt or an inbox item's text, one inbox item, the remembered decision, the chain, nothing pushed, clean exit.

## Who turns each step green

| Step | Workstream |
|---|---|
| Preflight | Phase 0 (passes today) |
| 1. Sphere up, team created, two Obis invited | Sphere server |
| 2. Two obids up with stub agents, and paired | Rust core, with the Sphere server |
| 3. B sends review_request via relay | Rust core and the Sphere server |
| 4. A has no remembered decision: inbox, accept and remember, job dispatched | Rust core |
| 5. Job finishes, scan clean, typed result via relay | Rust core and the Sphere server |
| 6. Second request accepted from the remembered decision | Rust core |
| 7. Audit chain holds both exchanges and verifies | Sphere server |
| 8. Final assertions | Both |

The step bodies (the `run` of each entry in `steps` in `e2e/run.mjs`) are written by the Rust core workstream, which may add helper files of its own under `e2e/lib/`; the Sphere server workstream proves its half in obi-sphere with its own tests and the conformance suite, against the same calls as steps 1, 3, 5 and 7. Everything else changes only through the lead: this document, `e2e/fixtures/`, the stub agent, the rest of `e2e/run.mjs` (preflight, the step loop, process handling), the lead's files in `e2e/lib/` (`fixture.mjs`, `scenario.mjs`, `scenario-doc.mjs`, `snapshot.mjs`: the scenario's fixed values and the checks' definitions), the `Makefile` and `.github/workflows/e2e.yml`. A step body that needs one of them changed asks the lead.
