# obid's work as workflows of typed nodes

A design, no code yet (2026-10-18). The owner wants Oby to drive Claude Code, Codex and Cursor (and cheap API models) as interchangeable harnesses, save money doing it, and build on his Go framework [new-blok](https://github.com/well-prado/new-blok), where everything is a workflow of typed nodes. This document says how obid's work becomes explicit workflows now, in Rust, with new-blok's contracts, so the same flows can run on new-blok's engine later.

What it replaces: obid's work is written as long `async fn`s today (`Jobs::work` and `run_owner_job` in `core/crates/obid/src/jobs.rs`, the plan loop in `brain/turn.rs`, the conversation session in `brain/harness.rs`). They work, but nothing outside them can see their steps, resume them after a crash at the step that was under way, count what each step cost, or check a step's effects against Oby's rules in one place. Each of those is done by hand, per function, today.

What it keeps: every rule in AGENTS.md ("Rules Oby never breaks") and docs/runner-api.md. The runner API and the apps don't change; `pipeline`, `step` and the events come from the flow instead of from hand-kept fields.

## 0. The short version

- **A node** is one typed step: a Rust type with an input, an output, and a descriptor that says its name, version, JSON schemas, effects and capabilities, exactly as new-blok's `node.Descriptor` does. It fails in one of four classes: invalid, business, transient, uncertain.
- **A flow** is a recorded program of nodes: call, if, choose, each, parallel, wait for a signal, try/finally. obid writes it out as new-blok's JSON workflow document, so the file is the flow, and new-blok can run the same file later.
- **The journal** is a SQLite file in obid's home. Each node's output is committed before the next node starts. After a crash, a flow resumes from what was committed. An effect that leaves the machine and wasn't committed is **uncertain**: obid asks the world (did the push land?) and, when the world can't say, asks the owner. It never runs it again by itself.
- **Agents are one node**, `agent/turn`, over obid's adapters (Claude Code stream-json, `codex app-server`, ACP for Cursor and Gemini, and a new chat-completions loop of obid's own for cheap API models like DeepSeek). A **router** node picks the harness, account and model for each turn by the task and its cost.
- **Oby's tools** (`oby_jobs`, `oby_dispatch`, …) are flows exposed on obid's MCP server, as new-blok's MCP trigger exposes workflows. The engine checks each node's declared effects against Oby's rules before it runs.
- **Every node run** is an event, an inspectable record and, for model calls, a row in a usage ledger that budgets read.
- **Order:** in obid (Rust) first. new-blok becomes the engine once it has a public durable API and a Rust worker SDK; today its journal is under `internal/`, there is no sidecar binary and the Rust worker is a roadmap item (section 8).

## 1. Nodes

### 1.1 What new-blok has

Read at new-blok `6f67a47` (2026-10-09). new-blok has no `Node` interface: `node.Define(name, version, handler, ...Option)` makes a generic `Definition[I, O]` around `func(ctx, I) (O, error)`, and `node.Any` erases its types for the registry (`Invoke`, `DecodeOutput` to restore a journaled output). The registry is keyed by `name@version` and refuses the same key with other schemas (`incompatible_schema_descriptor`). The descriptor (`node/node.go`):

```go
type Descriptor struct {
    Name                 string          `json:"name"`          // ^[a-z][a-z0-9_/-]{0,127}$
    Version              string          `json:"version"`       // X.Y.Z
    Description          string          `json:"description"`   // required
    InputSchema          json.RawMessage `json:"inputSchema"`
    OutputSchema         json.RawMessage `json:"outputSchema"`
    Effects              []string        `json:"effects,omitempty"`
    RequiredCapabilities []string        `json:"requiredCapabilities,omitempty"`
    Deterministic        bool            `json:"deterministic"`
}
```

`Pure()` sets `Deterministic` and clears effects; `Effects(...)` clears `Deterministic`. `RemoteBoundary()` marks a node a worker runs across the runtime protocol; it is a private flag on `Any`, not part of the descriptor. Errors carry a class from `provider.ErrorClass`: `invalid`, `business`, `transient`, `uncertain` (`node.DomainError{Code, Class, Retryable, Uncertain}`; a panic, a deadline after dispatch or bad output count as uncertain).

### 1.2 obid's `Node`

A trait is the natural Rust form of `Definition[I, O]`; the erased form is what the registry and the engine hold.

```rust
pub trait Node: Send + Sync + 'static {
    type In: DeserializeOwned + Send;
    type Out: Serialize + DeserializeOwned + Send;

    fn descriptor(&self) -> &Descriptor;
    async fn run(&self, cx: &Cx, input: Self::In) -> Result<Self::Out, NodeError>;

    /// For a node with outgoing effects: whether the effect of `input` already happened, from
    /// the world (the remote has the commit, GitHub has the pull request). `Ok(Some(out))` is
    /// committed as the node's output; `Ok(None)` means it didn't happen; `Err` means the world
    /// can't say. Only asked when the journal holds a dispatched attempt with no result.
    async fn reconcile(&self, cx: &Cx, input: &Self::In) -> Result<Option<Self::Out>, NodeError> {
        Err(NodeError::uncertain("cant_reconcile", "this node can't tell whether it ran"))
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Descriptor {
    pub name: String,            // "publish/push", new-blok's grammar
    pub version: String,         // "1.0.0"
    pub description: String,
    pub input_schema: Value,     // JSON Schema, hand-written like brain/plan.rs's
    pub output_schema: Value,
    pub effects: Vec<String>,    // outgoing effects only (1.3)
    pub required_capabilities: Vec<String>,
    pub deterministic: bool,
    #[serde(skip)]
    pub boundary: Boundary,      // InProcess | Sandboxed: runs in a child process in the job sandbox
}
```

- **Schemas** are `serde_json::Value` written by hand, as obid already writes the brain's plan schema, and checked with the `jsonschema` crate obid already depends on. No schema-derive crate: the schemas are the contract with new-blok and with MCP clients, so they are written on purpose, and a test checks each against `serde`'s view of `In` and `Out` with a few samples.
- **Validation** is new-blok's: the name grammar, `X.Y.Z`, a description, capabilities `^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$`, at most 128. The registry refuses a second descriptor under the same `name@version` with other schemas.
- **The input is checked** against `input_schema` before `run`, and the output against `output_schema` after: a node that returns something its schema refuses failed (invalid output), as in new-blok.
- **`Cx`** carries the run and step identity, the stop signal (`watch::Receiver<Signal>`, as jobs have today), the step's budget (section 7), an event sink, and the handles a node may use (the store, `git`, the vault through `crate::secrets` only for nodes that declare it). A node never calls another node: flows compose, nodes don't (new-blok's rule too).
- **`boundary`** is new-blok's remote flag: `Sandboxed` nodes run a child process inside the job sandbox (an agent turn, a check). It isn't serialized, as in new-blok; on new-blok, a sandboxed node is a remote node run by obid's worker (section 8).

### 1.3 Effects and capabilities

new-blok's effects are free strings, and whether a step has any is the one thing that decides how its engine journals it: no effects, re-run it after a crash; effects, journal it before dispatch and never re-run it. obid needs one more distinction, because most of what obid does changes something **inside** a folder obid owns (the job's worktree, the conversation's room, the clone's refs), and re-running that is safe: an agent round interrupted by a restart carries on today with "obid restarted while you were working: carry on with this round", and that should stay.

So obid's effects come in two kinds:

- **Contained** (`local:`): stays inside something obid made for this run and inspects afterwards. Re-run after a crash, with a note. `local:worktree`, `local:room`, `local:clone-refs` (moving the job's branch in obid's own clone, `git::keep_commits`), `local:artifacts`, `local:jobs` (writes a job record), `local:inbox` (adds an item), `spend:model` (calls a model: costs money or a window's share, section 7).
- **Outgoing** (`out:`): leaves the machine or reaches a person. Journaled before dispatch, never re-run; uncertain after a crash unless `reconcile` settles it. `out:git.push`, `out:github.pull-request`, `out:github.check-run`, `out:github.issue`, `out:notify` (an alert to the owner's devices), `out:sphere` (an Obi-to-Obi message).

Exported to new-blok (section 8), outgoing effects become new-blok `effects` (so its engine journals them the same way), and contained ones become `requiredCapabilities` (`obid.local.worktree`): on new-blok, they say which worker can run the node, which is what they mean. A node with contained effects only is not `deterministic`, so new-blok re-runs it after a crash, as obid does.

Capabilities are what the **caller** must hold, checked before the node runs: `jobs.read`, `jobs.start`, `jobs.tell`, `inbox.answer`, `artifacts.publish`, `conversation:<id>`, `job:<id>`, `owner` (only the owner's own answer carries it: a device signature, an inbox answer from an app), `secret.use` (only obid's own publish and connection nodes). Section 6 is where these are checked.

### 1.4 Errors

```rust
pub struct NodeError { pub class: Class, pub code: String, pub message: String }
pub enum Class { Invalid, Business, Transient, Uncertain }
```

| Class | Means | obid examples | The engine |
|---|---|---|---|
| `Invalid` | The input was wrong; nothing happened. | A plan names a repository obid doesn't know; `rounds` outside 1 to 10; an attachment outside `home/attachments`. | Fails the step; never retries. A flow called from a tool returns the message as the refusal (the plan loop's refusal texts). |
| `Business` | The work said no, cleanly; nothing went out. | The check still fails after the last round; the secret scan found something; an account is at its limit; GitHub refused the push (protected branch). | Fails the step with its code, which a flow may branch on (`choose` on the code). Never retried. |
| `Transient` | Didn't happen, may next time. | `gh` or the network failed before sending; a 429 or 5xx from a model API; the brain's quick call killed at 10 s (`planner.rs` retries it once today). | Retried with backoff up to the node's `retries` (default 2), **only** if the node has no outgoing effect or was refused before dispatch. |
| `Uncertain` | It may have happened. | The push's process was killed after it started; a pull request call timed out; obid crashed between dispatch and commit. | Never retried. `reconcile`, then the owner (section 3.4). |

new-blok's engine is stricter: in a journaled run, any failure of a step that declares effects becomes `effect_outcome_uncertain` (`classifyJournaledFailure`, `internal/engine/engine.go`), even an invalid input. obid trusts its own nodes' `Invalid` and `Business` to mean "nothing went out" (both are returned before dispatch, or from a refusal the remote sent), which keeps "the scan found a secret" from becoming an owner question. On new-blok, the same nodes would need a `provider.Keyed` effect key or a reconcile to get that; section 8 lists it as a gap to raise upstream.

## 2. Flows

### 2.1 What new-blok has

`flow.Define[I, O](Spec{Name, Version, Durability}, func(*Builder, Ref[I]) Ref[O])` records a program without running a node. `Ref[T]` is a reference: `$input`, `$step.<id>[.field]`, or a literal. The builder has `Call`, `If`, `Choose`, `Each` (with a concurrency bound), `Parallel`, `TryFinally`, `Compare`, `Default`, `Template` and `Child`; `Lower()` turns the record into a `contract.InternalProgram` (and still refuses `Template` and `Child`, ADR 0028). The builder has no wait, approval or timer; the journal has durable waits (ADR 0027, in progress) and the lowering refuses a wait inside a loop. `Durability` has one value today, `memory`.

The canonical document (`contract/document.go`, version 1) is what a file holds:

```json
{"version": 1,
 "workflow": {"id": "quote", "name": "shop/quote", "version": "1.0.0", "digest": "sha256:…",
              "inputSchema": {…}, "outputSchema": {…},
              "instructions": [
                {"id": "calculate", "kind": "call", "node": "quote-node"},
                {"id": "respond", "kind": "output", "references": [{"step": "calculate", "path": ["totalCents"]}]}]},
 "nodes": [{"id": "quote-node", "version": "1.0.0", "digest": "sha256:…", "inputSchema": {…}, "outputSchema": {…}}],
 "bindings": [{"id": "http-quote", "kind": "http", "workflow": "quote"}]}
```

Its instruction kinds are `call`, `condition`, `output`, `wait` (`{"name", "timeoutMillis"}`) and `parallel`; references point only at earlier instructions, and there is no expression language. The control instructions `Lower()` makes (if, choose, each, try-finally, compare, default) live in the internal program (format 2), as a `control` body: `{"operator", "operands": [{"reference"} | {"literal"}], "arms": [{"name", "match", "instructions", "output"}], "concurrency"}`, arms named `then`/`else`, `case-<n>`/`default`, `try`/`finally`, `body`, `0`…`n-1`.

### 2.2 obid's flows

The same shape, in Rust: a builder that records, and an interpreter that runs the record. The Rust closure runs once, when obid starts, to build the document; after that the document is the flow.

```rust
pub fn owner_job() -> Flow {
    Flow::define("job/owner", "1.0.0", |b, input: Ref<JobInput>| {
        let route = b.call("route", &nodes::Route, input.select("routing"));
        let tree = b.call("prepare", &nodes::PrepareWorktree, input.select("repo"));
        …
        b.output(…)
    })
}
```

Steps and their place in the document:

| Builder | Document | Notes |
|---|---|---|
| `call(id, node, input)` | `call` | The input is a reference or an object of references (`Template` in new-blok, refused by its lowering today; obid only builds objects from references and literals, no text templates). |
| `if_(cond, then, else)` | `control` `if`, arms `then`/`else` | `cond` is a `compare` of two references or literals (`eq`, `ne`, `lt`, …). |
| `choose(on, cases, default)` | `control` `choose`, arms `case-<n>`/`default` | Matches a string: an error code, a verdict, a harness. |
| `each(items, concurrency, body)` | `control` `each`, arm `body` | Iterations don't see each other's outputs (new-blok's rule). |
| `parallel([a, b, …])` | `parallel` / `control` `parallel`, arms `0`… | |
| `try_finally(try, finally)` | `control` `try-finally` | The job's "whatever ended it, keep its commits" (`work`, today). |
| `wait(name, timeout)` | `wait` `{"name", "timeoutMillis"}` | A signal (section 2.4). Never inside `each`, as new-blok's lowering refuses. |
| `repeat(max, until, body)` | obid only; exported as nested `if`s | Rounds (section 4). new-blok has no loop that sees the previous pass: exporting unrolls it `max` times, each pass inside an `if` on the previous pass's `until`. |

- **Only flows obid ships run.** They're Rust code in obid, built at start, each with its `digest` (sha256 of its document). No agent, brain, plug-in or other Obi authors a flow or picks a node by name; they pick a flow that obid exposes (section 6), with an input its schema checks. A flow from a file is for new-blok later, not for obid's interpreter.
- **The document obid writes** is new-blok's version 1 document with the `control` body on instructions, as the internal program has it. That's one field more than new-blok's public document carries today; section 8 asks new-blok to take `control` into `contract.Document` (or to make the internal program a public format). Until then obid's export tool writes both: the document, and the lowered internal program.
- **Durability** per flow: `durable` (jobs: resumes after a crash, section 3) or `memory` (a conversation turn: journaled for inspection and the ledger, but a crash fails the turn with one line, as today; its dispatched outgoing effects still become uncertain, never re-run).

### 2.3 Bindings

new-blok's `bindings` say what starts a workflow (`http`, `webhook`, `worker`, `cron`, `pubsub`, `grpc`, `sse`, `websocket`, `mcp`). obid's starts:

| obid today | Binding |
|---|---|
| `POST /v1/jobs`, a plan's `dispatch`, `oby_dispatch` | `http` / `mcp` → `job/owner` |
| `POST /v1/plans` | `http` → `conversation/turn` |
| An Obi-to-Obi review request | `webhook` (the Sphere's) → `job/obi-review` |
| PR following every 3 minutes (`follow_pull_requests`) | `cron` → `github/follow-prs`, which sends signals (2.4) |
| Each `oby_*` tool | `mcp` → its flow (section 6) |
| A job's or check's event for the orchestrator (#590) | internal → `orchestrator/event` |

### 2.4 Signals

A wait names a signal; something sends it to the run: `{run, name, payload}`. new-blok's `signal.Envelope{RunID, SignalID, Name, Payload, Principal}`, kept in the journal (`journal_signals`, `journal_waits`). obid's:

- `owner.words`: the owner told a job something (`POST /v1/jobs/{id}/messages`). Today they queue in `job.heard` and the agent hears them at its next turn; in a flow, the next `agent/turn` takes them as input through a `job/take-heard` step, which is journaled, so a replay hears the same words.
- `owner.answer`: an inbox item was answered (a permission in Ask mode, a confirm, an uncertain effect).
- `pr.state`: the PR follower saw the pull request change (reviewed, merged, closed).
- `check.result`: a Mac or Apple check reported (`POST /v1/checks/{id}/result`).
- `start-when`: what a job waits for before it starts held (another job done, an account with room, a time, #216).

## 3. The journal

### 3.1 Where

obid keeps its state as one JSON file per thing today (`store.rs`: written whole and renamed into place; `oby.sqlite` is the Swift app's, not obid's). The journal is obid's first SQLite file, `home/journal.sqlite` (0600, WAL), through `rusqlite` with its bundled SQLite. A file of appended lines per run would do for resuming one run, but the ledger and budgets ask across runs ("what did account Personal spend today"), waits need claiming, and one node's commit writes its output, its attempt and its usage row together: one SQLite transaction does all of that. new-blok made the same choice (ADR 0003, SQLite as the embedded durable backend).

Job records stay where they are (`home/jobs/<id>.json`): the apps read them through the API, and a job's run points at its job. The journal holds runs, not jobs.

### 3.2 Tables

A subset of new-blok's `internal/journal` schema, same names where they mean the same thing, so the two read alike:

```sql
CREATE TABLE runs (
  id TEXT PRIMARY KEY,           -- uuid
  flow TEXT NOT NULL,            -- "job/owner@1.0.0"
  digest TEXT NOT NULL,          -- the flow document's sha256: a resumed run checks it's the same flow
  subject TEXT,                  -- "job:9f08fd10", "conversation:…/turn:12"
  request_key TEXT UNIQUE,       -- what started it, so a retried request starts nothing twice
  input_json TEXT NOT NULL,
  state TEXT NOT NULL,           -- running | waiting | done | failed | uncertain | stopped
  output_json TEXT, error_class TEXT, error_code TEXT, error_text TEXT,
  created TEXT NOT NULL, updated TEXT NOT NULL
);
CREATE TABLE operations (
  key TEXT PRIMARY KEY,          -- sha256 of {run, digest, invocation path, iteration path}
  run TEXT NOT NULL REFERENCES runs(id),
  step TEXT NOT NULL,            -- the instruction id
  invocation_path TEXT NOT NULL, -- arms crossed: "try/round-2/then"
  iteration_path TEXT NOT NULL,  -- each and repeat indexes: "2"
  node TEXT NOT NULL,            -- "publish/push@1.0.0"
  input_digest TEXT NOT NULL, input_json TEXT NOT NULL,
  state TEXT NOT NULL,           -- intent | dispatched | committed | failed | uncertain
  attempts INTEGER NOT NULL DEFAULT 0,
  result_json TEXT, error_class TEXT, error_code TEXT, error_text TEXT,
  settled_by TEXT, evidence TEXT, -- who settled an uncertain one (reconcile, or the owner) and how
  started TEXT, finished TEXT
);
CREATE TABLE waits (
  run TEXT NOT NULL, invocation_path TEXT NOT NULL, iteration_path TEXT NOT NULL,
  name TEXT NOT NULL, due TEXT, state TEXT NOT NULL,  -- waiting | signalled | timed-out
  signal TEXT, payload_json TEXT,
  UNIQUE (run, invocation_path, iteration_path)
);
CREATE TABLE signals (id TEXT PRIMARY KEY, run TEXT NOT NULL, name TEXT NOT NULL,
  payload_json TEXT, principal TEXT NOT NULL, received TEXT NOT NULL, consumed TEXT);
CREATE TABLE usage (…);          -- section 7.2
```

Values in `input_json`, `result_json` and `payload_json` went through obid's redaction first (`crate::secrets`): no vault secret, token or login is ever written, as no event or log carries one today.

### 3.3 Commit order

For each step, in order:

1. **Replay.** If the step's operation is `committed`, its result is the step's output; nothing runs. A different `input_digest` for the same key is a conflict: the run fails (`request_conflict`, as new-blok's `ErrRequestConflict`), since the flow or its inputs changed under it.
2. **Check** (section 6): capabilities, effects against the run's rules, the budget. A refusal fails the step `Invalid` (or makes an inbox item and waits, for an ask).
3. **Intent.** A node with outgoing effects: write the operation `dispatched` with its input and `attempts + 1`, and commit, **before** it runs. Contained and pure nodes skip this; their operation is written at the end.
4. **Run** the node.
5. **Commit** in one transaction: the operation `committed` with its result (or `failed` with its class), its usage rows, the consumed signal if it was a wait, the run's `updated`. Then the event goes out (section 7.1). Only then does the next step start.

### 3.4 After a crash

When obid starts, every run in `running` resumes (jobs today: `Jobs::resume` reschedules queued jobs and the round carries on; a flow does it per step):

- Steps already `committed` replay their results.
- A contained or pure step that was under way runs again. For `agent/turn` that's what happens today: the same session resumed, told it was interrupted.
- An outgoing step found `dispatched` (started, never committed) is asked `reconcile`:
  - `publish/push`: `git ls-remote` on the job's branch. The commit obid pinned is there: committed, with the evidence. It isn't: the push didn't happen, and the step runs (it's the same pinned commit, `--force-with-lease` against what obid pushed last).
  - `publish/pull-request`: `gh pr list --head <branch> --state all`. One is there: committed. None: runs.
  - `github/check-run`: obid's own check run by name on the commit; `PATCH` it rather than add one, as today.
  - `notify`, `sphere`: can't tell. Uncertain.
- **Uncertain**: the operation and the run are marked `uncertain`, and an inbox item asks the owner, saying what was under way and what obid knows: "obid stopped while it was opening the pull request for *Fix login*. GitHub shows none on `oby/fix-12`. Open it now / Leave it." Their answer is the `owner.answer` signal: `settled_by: owner`, and the run goes on, or stops. obid never runs an uncertain effect again by itself; new-blok settles them the same way, through an audited `Journal.Reconcile(opKey, actor, evidence, result, authorized)`.
- A wait whose time passed while obid was down times out, once (new-blok persists the deadline once, too).

## 4. obid's work as flows, on paper

These are what obid does today (`jobs.rs`, `publish.rs`, `brain/`), drawn as flows: no new behaviour. Node names are `area/verb`; effects in brackets.

### 4.1 A job (`job/owner@1.0.0`)

```
input: the job (repo, base, branch, task, kind, agent?, account?, model?, mode, rounds, check?, attachments, issue?, pr?)

route         call  agent/route              [pure]                        → {harness, account, model, effort, why}
prepare       call  git/prepare-worktree     [local:clone-refs, local:worktree]  clone or fetch, branch, detached worktree
inputs        call  job/quote-inputs         [local:worktree]              attachments and issue files into .obi/inputs
try:
  rounds      repeat max=input.rounds until=round.done:
    heard     call  job/take-heard           [local:jobs]                  the owner's words since the last turn
    turn      call  agent/turn               [local:worktree, spend:model] (section 5)
    check     if input.check:
                call job/check               [local:worktree]              the check command, in the sandbox
    done      call  job/judge-round          [pure]                        check passed, GOAL MET, or rounds left → {done, next_prompt}
finally:
  artifacts   call  artifacts/publish-job    [local:artifacts]             .obi/artifacts/ → artifacts
  keep        call  git/keep-commits         [local:clone-refs]            the worktree's commits onto the job's branch
if keep.commits == 0 → output (done, nothing to publish)
publish       call  flow job/publish (inlined)
output: the job's end (done, summary, commits, pushed, pull request)
```

`job/publish` (also run by "Publish by hand", with the device signature as the `owner` capability):

```
scan          call  publish/scan             [pure]       every added line, message, file read whole, branch name, PR text → {head, clean, findings}
choose scan.clean:
  false → if rounds left and findings differ from last time:
            round   (the rounds body again, told to rewrite the commits; the scan again)
          else → fail Business "secret_found"
  true  →
    push      call  publish/push              [out:git.push]               reconcile: ls-remote sees head
    pr        call  publish/pull-request      [out:github.pull-request]    reconcile: gh pr list --head
    review    wait  pr.state                  (obid doesn't run Oby's review yet, #525: a person reviews on GitHub)
```

`publish/push` takes `scan`'s output as its input and its schema has `"clean": {"const": true}` and the `head` it pushes: a push can't be built from anything but a clean scan of the same commit. The `job` record's `pipeline` stages (`prepare`, `work`, `check`, `publish`, `review`, `merged`) and `publishStep` (`scan`, `push`, `pullRequest`) become views of these steps' states.

What's left out on purpose: the merge. obid never merges (runner-api.md, "obid only: what obid leaves out"), so there is no merge node, and no flow can have one.

### 4.2 A conversation turn (`conversation/turn@1.0.0`, `memory`)

```
input: {conversation, words, device?, attachments}

recap         if owner was away > 30 min: call brain/recap        [spend:model]
route         call  agent/route              [pure]                → harness for talking (Settings › Models › Conversations), or none
choose route.harness:
  none →      call  flow brain/plan-loop     (4.3: no account signed in, or the session failed twice)
  else →
    room      call  conversation/prepare-room [local:room]         read-only checkouts refreshed when the default branch moved
    turn      call  agent/turn                [local:room, spend:model]
                    tools: the agent's own (Read, Grep, WebSearch, WebFetch, Write in the room, Task, TodoWrite)
                           + Oby's tools, each a flow over MCP (section 6), each a child run of this one
    if turn failed twice → call flow brain/plan-loop, and say so in one line
record        call  conversation/record-turn  [local:jobs]          the turn, its steps, its artifacts
```

### 4.3 The plan loop (`brain/plan-loop@1.0.0`, `memory`)

```
brief         call  brain/briefing           [pure]                the conversation, jobs, inbox, accounts (quoted parts to work.md)
steps         repeat max=8 until=step.ended:
  plan        call  brain/plan               [spend:model]         one typed action (Claude Code, then Codex, then rules)
  valid       call  brain/check-plan         [pure]                Plan::problems; refused → plan again once with why
  act         choose valid.action:
                reply | question → end
                read_job | find | research → call brain/read… [pure or local] → quoted for the next step
                dispatch | retry_job | tell_job | stop_job | move_job | answer → call the same flow as the matching oby_* tool (section 6)
completeness  call  brain/check-handled      [spend:model]         everything the user named was handled (#539)
```

The orchestrator (#590) is the same loop with its own allow-list and daily caps, started by an internal binding instead of the owner's words. The Lead (#589) is `brain/lead@1.0.0`: read the board, `plan`, check, start each job's flow, claim each issue after the scan.

## 5. Agents as nodes

### 5.1 One node: `agent/turn`

Every adapter obid has already shares one shape (`agent.rs`: `Launch`, `Ruling`, `Event`, `Turn`). The node is that shape with a schema:

```
agent/turn@1.0.0   [local:worktree | local:room, spend:model]   boundary: Sandboxed
input:  {harness: "claude" | "codex" | "acp:cursor" | "acp:gemini" | "api:<provider>",
         account, model, effort?, session?, folder: {kind: "worktree" | "room", path},
         prompt, quoted: [paths],               // what others wrote, as files, never in the prompt
         tools: {own: [...], oby: [flow names]},
         budget: {maxTurns, deadlineMs, maxUsd?}}
output: {ok, session, text, structured?, exit, timedOut, stopped, notes,
         usage: {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costUsd?, costSource},
         rateLimits?: {fiveHour, sevenDay}}
```

- **Claude Code**: `agent::run` as today (`claude -p` stream-json, `--permission-prompt-tool stdio`, never `--bare`, the environment cleaned of `CLAUDECODE`, `CLAUDE_CODE_*`, `ANTHROPIC_*`). Usage from its `result` line (`usage`, `total_cost_usd`) and `rate_limit_event`.
- **Codex**: `codex::run` (`app-server`, `thread/start` or `thread/resume`, `turn/start`; approvals answered by obid's policy).
- **ACP**: `acp::run` for Cursor today (`cursor-agent acp`); Gemini (`gemini --acp`) is one more launch line on the same adapter.
- **`api:<provider>`**: new (5.3).

Every permission prompt inside the turn is still answered by obid's policy (`policy.rs`, `permissions.rs`), as now; the node doesn't change that. What the node adds: its usage lands in the ledger, its budget is enforced, and it can be retried, routed and inspected like any other step.

### 5.2 The router: `agent/route`

A pure node: its input is a snapshot (the task, the owner's words about agents, each account's sign-in, windows and limits, the price table), so a replay routes the same way. `job/owner` and `conversation/turn` call it first.

```
agent/route@1.0.0   [pure]
input:  {purpose: "job" | "conversation" | "review" | "brain" | "recap" | "summary",
         kind?, complexity?, named: {agent?, account?, model?},
         accounts: [{id, harness, signedIn, fiveHour?, sevenDay?, ahead?, limitUntil?}],
         prices: {<model>: {inputPerMTok, outputPerMTok, cacheReadPerMTok}},
         needs: {tools: "repo-write" | "repo-read" | "none", vision?, contextTokens?}}
output: {harness, account, model, effort, why}
```

In order:

1. **The owner's words win.** A named agent, account or model is used, or the route says why it can't be (signed out, at its limit), as `pick` does today.
2. **What the work needs.** Writing a repository needs a coding harness (Claude Code, Codex, Cursor) in the job sandbox. Reading and talking can use any. No tools at all (a recap, a summary, a title, compaction) can use an API model.
3. **Subscription windows before money.** An account on a plan costs nothing per call until its window fills; skip one at its limit or over the share routing calls busy (80% of a window, as `startWhen` has it), prefer one running ahead of its weekly pace for short work (as Oby's review picks its account today).
4. **Cheap where it's enough.** For talking, OpenMausBot's split works and is cheap to copy as an idea: a turn is simple when it's short, has no code, no attachment and no action words, and doesn't follow a turn that used tools; a simple turn goes to the quick model of the same harness (Haiku) or a cheap API model, and only while the conversation's context fits that model's window. Complex jobs get the strong model offered, never applied on their own (`complexity` in `plan.rs` today).
5. **Cost as the tiebreak**, from the price table, when two choices are otherwise equal.

`why` is one line ("Codex · Work: Personal is at 92% of its 5-hour window"), shown with the job, so routing is never a mystery.

### 5.3 obid's own loop for API models

`api:<provider>` is a small chat-completions loop in obid (OpenAI-compatible: DeepSeek, and anything else that speaks it): send the messages and the tools, run the tool calls the model asks for, send the results, until it answers or the budget ends. It's what makes cheap models useful for the work that doesn't need a coding harness: recaps, summaries, a conversation's quick answers, and later the brain's quick plan.

- **Its tools are Oby's tools only** (section 6) plus, for a conversation, reading files in the room. No shell, no write outside the room, no web unless the conversation allows it. It runs in obid's process, so it has no sandbox of its own: anything it does goes through a node that obid checks.
- **The key** is a connection the owner made, in obid's vault. obid sends it to the provider; it never reaches the model, a prompt, an event or a log ("Rules Oby never breaks": a secret is used only for a connection the user made).
- **Prompt caching**: the system prompt and the tool list stay byte-identical across calls; what changes goes in the newest user message (OpenMausBot's split into a stable and a volatile part; DeepSeek Harness's "in-history" updates). Providers' automatic prefix caching then pays for itself; the ledger records cache reads apart from input to show it.
- **Compaction**: when the context reaches 80% of the model's window (less the output cap), fold the older part into a summary made by the same model on the same cached prefix, keep the last two exchanges word for word, and keep the summary as a turn of its own. Both prior-art projects do roughly this; obid's version is the same rule in fewer words. Claude Code and Codex compact their own sessions; obid only does it for this loop.

## 6. Oby's tools as flows

### 6.1 The MCP server

Today `brain/tools.rs` serves Oby's tools at `POST /v1/agent/mcp/conversation-<id>`, each call checked as the plan loop checks a plan and done by `brain::actions`. In the flow design, each tool **is** a flow with an `mcp` binding, as new-blok's MCP trigger exposes workflows (`trigger/mcp`, ADR 0014):

| Tool | Flow | Effects (of its nodes) | Capability |
|---|---|---|---|
| `oby_jobs`, `oby_job` | `oby/jobs`, `oby/job` | pure | `jobs.read` |
| `oby_inbox` | `oby/inbox` | pure | `inbox.read` |
| `oby_conversations` | `oby/conversations` | pure | `conversations.read` |
| `oby_read`, `oby_search`, `oby_list` (being added now) | `oby/read`, `oby/search`, `oby/list` | pure | `files.read` |
| `oby_dispatch` | `oby/dispatch` → starts `job/owner` | `local:jobs` | `jobs.start` |
| `oby_tell_job`, `oby_stop_job` | `oby/tell-job`, `oby/stop-job` | `local:jobs` | `jobs.tell` |
| `oby_answer` | `oby/answer` | `local:inbox` | `inbox.answer` (not `owner`) |
| `oby_artifact` | `oby/artifact` | `local:artifacts` | `artifacts.publish` |

- **Names stay** (`oby_dispatch`): new-blok names an MCP tool `strings.ReplaceAll(name, "/", ".") + "_v" + version` (`oby.dispatch_v1.0.0`). obid's binding carries the tool's name explicitly; section 8 asks new-blok's MCP binding for the same.
- **The input schema is the flow's**, `readOnlyHint` is "no effects", as new-blok does, and only the listed flows are exposed (new-blok's `Config.Expose`).
- **The token decides the principal.** A conversation's turn token holds `conversation:<id>` and the read and start capabilities; a job's connected-app broker token holds `job:<id>` and none of Oby's; nothing an MCP client sends widens it (new-blok: "principal trust cannot come from caller JSON").
- **Each tool call is a child run** of the agent's turn, with its own operations, so the conversation's inspector shows "turn → oby_dispatch → job/owner started". Its request key is `{turn run, tool call id}`: a retried call starts nothing twice. If the turn itself is re-run after a crash, its note lists the tool calls that already ran.

### 6.2 Rules checked per node, from its declared effects

The engine checks every node before step 3 of 3.3, against the run's rules: the rules are data about effects, not code in each function. What AGENTS.md says, as checks:

| Rule (AGENTS.md, runner-api.md) | Check |
|---|---|
| Agents run in the sandbox. | A node whose `boundary` is `Sandboxed` gets its `Launch` only from `Jobs::boxed_launch`; a node that writes a folder declares `local:worktree` or `local:room`, and its run's folder is the only one its sandbox can write. A flow with a `Sandboxed` node and no folder fails to build. |
| No code-host login for agents; only Publish pushes. | `out:git.push` and `out:github.*` are allowed only to obid's `publish/*` and `github/*` nodes, which run in obid's process with obid's `gh`. No `Sandboxed` node may declare an `out:` effect: the registry refuses it. |
| Nothing goes out unless the check passed and the scan is clean. | `publish/push` and `publish/pull-request` take a `publish/scan` output with `clean: true` for the same `head` as input (4.1); the run's `job/judge-round` output must be `done`. |
| Secrets never reach an agent. | Only nodes holding `secret.use` touch `crate::secrets` (publish, connections, the API loop's provider call). The flow builder refuses a reference from a `secret.use` node's output into a `Sandboxed` node or `agent/turn`, and every output is redacted before it's journaled or sent as an event. |
| Text from others is data. | `agent/turn`'s input has `quoted` (files) apart from `prompt`; nodes that read GitHub, the web, a plug-in or another Obi return `{quoted: path}`, and the builder refuses a reference from one into a `prompt`. |
| Approvals are inbox items. | An effect the run's mode marks *ask* (Ask mode's prompts, a confirm for what persists or widens trust, Bypass starts) makes an inbox item and waits for `owner.answer`; only the owner's answer carries `owner`. `oby_answer` never carries it, so the owner's own decisions are refused with why, as now. |
| obid never merges. | There is no merge node, and the registry refuses an effect named `out:github.merge`. |
| Every outgoing action is listed. | Each committed `out:` operation is appended to the job's `outgoing` (ids only, never what was sent), as `publish.rs` does now. |

These replace scattered checks with one place to read them; they don't replace the sandbox. As new-blok's roadmap says of its own manifests, a declaration doesn't sandbox code: bubblewrap and Seatbelt still hold an agent in, the invalid push URL still holds a push back, and the policy still answers each permission prompt.

## 7. Inspection, events, usage and budgets

### 7.1 Events and inspection

- **One event per step change**: new-blok's inspection kinds, `run.started|completed|failed|canceled|suspended|uncertain` and `step.processing|completed|failed|canceled|uncertain`, sent as an SSE event `flow` (`{run, flow, subject, step, node, state, class?, code?, usage?}`), redacted.
- The events apps have today (`job`, `step`, `thinking`, `delta`, `turn`, `artifact`) don't change; obid makes them from the flow's steps, so a job's `pipeline` stops being kept by hand.
- **Inspection API** (obid only, loopback, not on the gateway): `GET /v1/runs?subject=&state=`, `GET /v1/runs/{id}` (the flow's document, every operation with its state, attempts, timing, usage and settlement), `GET /v1/flows` (each flow's document and digest: what obid can run).

### 7.2 The usage ledger

Today only the brain's own calls are measured: each `Call` in the brain's turn records (`brain/planner.rs`) keeps its tokens, cache reads and writes and `total_cost_usd`. Jobs and conversations record nothing, and obid has no account usage (#450). The ledger is one row per model call, the brain's included, with the `Call` record's fields:

```sql
CREATE TABLE usage (
  id INTEGER PRIMARY KEY, run TEXT NOT NULL, operation TEXT NOT NULL, at TEXT NOT NULL,
  subject TEXT,                 -- job:… | conversation:… | brain | recap | review
  purpose TEXT NOT NULL,        -- as agent/route's
  harness TEXT NOT NULL, account TEXT NOT NULL, model TEXT NOT NULL,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
  cost_usd REAL,                -- what the harness reported, else from the price table, else null
  cost_source TEXT NOT NULL,    -- reported | price-table | subscription | unknown
  five_hour REAL, seven_day REAL -- the window shares the harness reported, when it did
);
```

Never the words. Rows are written in the step's commit (3.3). From it: what a job cost, what each account and API key spent today and this month, cache hits, and the window shares `startWhen` and routing read.

### 7.3 Budgets

- **Per step**: `agent/turn`'s `budget` (`maxTurns`, `deadlineMs`, `maxUsd`): obid passes what the harness takes (`--max-turns`, the time limit it enforces today: 45 minutes a round) and enforces the rest itself in the API loop.
- **Per run**: a job or turn's total (`maxUsd`, wall time), checked before each `spend:model` step; past it, the step fails `Business` `budget_spent` and the job ends "Stopped at a limit", the branch kept, as limits do today.
- **Per account or key, per day and per month**: from Settings, checked before each `spend:model` step on that account; past it, routing skips the account, and a named one fails with why.
- A budget is never a reason to run anything again; it only stops what would start.

## 8. Migration: Rust first, new-blok later

### 8.1 Where new-blok is (read 2026-10-18, commit `6f67a47`)

- **Durability is internal.** The journal (`internal/journal`), the engine (`internal/engine`) and the resumer are under `internal/`: nothing outside the module can use them. ADR 0001 keeps public API boundaries; no public durable API exists yet. ADR 0027 (durable waits) and 0028 (lowered control flow: each and parallel durable now; durable child runs and resume at start not yet) are in progress.
- **No sidecar.** There is no new-blok binary obid could run beside it.
- **No Rust worker.** The worker protocol is `blok.runtime.v1` over one gRPC stream (`contract/runtime/runtime.proto`, ADR 0004, pre-alpha), with Node.js the only external SDK and runtime. `sdk/rust` and `runtime/rust` are planned (E19-T03, #89, milestone M8); neither exists.
- **No LLM loop, no CLI driving, no MCP client, no cost accounting.** `agent/` is a catalog with approvals and budgets (`tool.Budget{MaxDepth, MaxInputBytes, MaxOutputBytes, MaxTokens, MaxCalls, Deadline}`), not an agent.
- **What fits obid already**: the descriptor, the error classes, the document, the journal's model (intent, dispatched, committed, uncertain; settled by an audited reconcile), approvals as journaled decisions (ADR 0008), the MCP trigger (ADR 0014), inspection kinds (ADR 0016).

### 8.2 The path

1. **obid runs its own flows** (sections 1 to 7), in Rust, with new-blok's names and shapes. obid's export writes each flow as new-blok's document, and a test checks it against new-blok's own validation (a copy of `testdata/contracts/valid.json`'s rules: id grammar, references to earlier steps only, 1 MiB, depth 64).
2. **Ask new-blok for what obid needs**, as issues there, each small:
   - `control` (if, choose, each, try-finally) in the public `contract.Document`, not only the internal program.
   - A bounded loop that sees the previous pass (`repeat max until`), or an accepted way to unroll one.
   - An explicit tool name on the `mcp` binding.
   - A way for an effectful node to say "refused before dispatch" (`invalid`/`business` without becoming uncertain), or a documented `provider.Keyed` route for it.
   - Contained effects (re-run on crash, but not pure): today only "no effects" gets that, which works but hides what the node writes.
3. **When new-blok has a public durable API, a sidecar or embeddable engine, and the Rust worker SDK**, obid becomes a worker: its nodes register over `blok.runtime.v1` (the `Sandboxed` ones as remote nodes, with obid's capabilities), new-blok runs the same flow documents, and obid's interpreter and journal go. Runs in flight finish on obid's engine; new runs start on new-blok's. No journal data moves.
4. **What stays in obid either way**: the adapters, the sandbox, the policy that answers permission prompts, the scan and the publish gate, the vault. new-blok runs flows; it doesn't hold Oby's trust boundary.

The test for step 3: a job flow runs on new-blok with obid as its worker, obid is killed during `publish/push`, and after both restart the push is reconciled, not repeated.

## 9. Prior art (ideas only)

Read 2026-10-18. Neither project's code or prompt text goes into Oby; these are the mechanisms worth knowing.

- **OpenMausBot** (github.com/milind-soni/OpenMausBot, Apache-2.0; its `enterprise/` folder is source-available and its names aren't licensed, so neither is used). Drives `claude -p` stream-json, `codex app-server` and ACP agents (Cursor, Gemini and others) behind one driver interface (`sendTurn`, `interruptTurn`, `respondToRequest`, `steer`), plus a shared chat-completions runtime for API models. Routing is per turn and by rule: a turn is simple or complex by length, code, attachments, action words and whether the last turn used tools; simple goes to the same provider's fast model, or lower effort, and never when the thread's context is past 60% of that model's window. Caching splits the system prompt into a stable and a volatile half and only notes volatile changes in the newest user message; it also pings subscription sessions to keep a long cache warm. Compaction at 80% of the window keeps the last two exchanges and adds a short helper-model summary with quoted excerpts. A usage ledger appends one line per turn (model, input, output, cached input, cost and where the cost came from) to a monthly file, with a monthly spend cap. No workflow engine; cron routines.
- **DeepSeek Harness** (github.com/deepseek-ai/deepseek-harness, MIT). Everything, the loop, tools, sandbox, approvals and compaction, is an in-process Cordis plugin sharing one context, with no isolation between plugins. It runs its own loop on DeepSeek's Messages API, and drives Claude Code (through the Agent SDK), Codex (`app-server`) and ACP agents only as subagents behind a `SubagentProvider` interface. Caching keeps the prefix byte-identical and appends prompt changes after the history. Compaction triggers at the smaller of 80% of the window and the window less the output cap less 64k, keeps the newest 16% word for word, and summarizes on the same cached prefix. Its sandbox fails closed (Seatbelt, bubblewrap, Landlock), with `read-only`, `workspace-write` and `danger-full-access`. Records tokens per call, cache reads and writes apart; no cost ledger or budget. A small workflow API (`agent`, `parallel`, `pipeline`, `phase`) for scripts it runs in a fresh, sandboxed process.

What Oby takes: OpenMausBot's turn split for routing and its stable/volatile prompt split, both projects' compaction rule (80%, keep the newest, summarize on the cached prefix), and a ledger that keeps cached tokens apart. What it doesn't: in-process plugins with shared state (Oby's plug-ins run out of process, `obi-plugin-host`), and drivers that answer permission prompts by the agent's own mode instead of obid's policy.

## 10. First pull requests, in order

Each is small, reviewable and leaves obid working; no behaviour changes until 5.

1. **This document.**
2. **Nodes and documents** (`core/crates/obid/src/flow/`): `Node`, `Descriptor`, `NodeError`, the registry with new-blok's validation, the document types with `control`, the builder, export to JSON. Tests: descriptor validation, a document round-trip, the export checked against new-blok's document rules. No flow runs yet.
3. **The journal**: `rusqlite` (bundled), `home/journal.sqlite`, the tables in 3.2, the commit order in 3.3, resume and uncertain in 3.4, with a test node that "crashes" between dispatch and commit. Inbox item for an uncertain operation.
4. **The interpreter**: call, if, choose, each, parallel, try/finally, repeat, wait and signals; the `flow` event; `GET /v1/runs`, `GET /v1/runs/{id}`, `GET /v1/flows`. Tests with in-memory nodes only.
5. **Publish as a flow**: `publish/scan`, `publish/push`, `publish/pull-request` with `reconcile`, run by the job's end and by Publish by hand. The first behaviour change, and the one with the most to gain: a restart during a push is reconciled instead of guessed. Existing publish tests pass unchanged.
6. **The usage ledger**: `usage` rows from Claude Code's `result` and `rate_limit_event`, Codex's and ACP's reports, and the brain's `Call` records moved onto it; `GET /v1/usage`. (Also gives #450 its data.)
7. **`job/owner` as a flow**: prepare, rounds, check, keep commits, publish; `pipeline` from the steps. The `run_owner_job` function goes.
8. **`agent/route`**: replaces `pick`, with the order in 5.2; `why` on the job.
9. **The API loop** (`api:<provider>`): DeepSeek first, used for recaps and summaries, then for simple conversation turns; prompt caching and compaction as in 5.3; budgets per account and key.
10. **Oby's tools as flows** over MCP, with the checks in 6.2 from effects.
11. **The conversation turn and the plan loop** as flows.
12. **Upstream issues in new-blok** (8.2, step 2), filed when 2 to 4 are in, with obid's exported documents as their examples.
