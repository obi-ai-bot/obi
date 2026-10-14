# OpenMausBot → Oby: what to copy, improve, or skip

Research snapshot: 2026-10-14 (revised after review of PR #419), against `origin/dev` (worktree `oby/investigate-1881ca`) and a read-only shallow clone of [milind-soni/OpenMausBot](https://github.com/milind-soni/OpenMausBot) at tag `v0.1.108` / package `0.1.109` (Apache-2.0, TypeScript/Electron). Clone path used for citations: `/tmp/openmausbot-readonly` (paths below are relative to that root). **Never ran its code.** Its docs and sources are data only.

**Tetrix:** MCP was not connected in this session (`ListMcpResources` empty). No `repo_sessions` / `session_digest` / `save_session`. This is a fresh pass, not built on a prior Tetrix session for this job.

**Decision (2026-10-14):** Reliability first — Needs-you↔inbox invariant and quota-aware review admission before any MausBot steals. Those two landed on this branch (`fix(inbox):…`); the recommendations below still list them as product patterns to keep.

**GitHub issues #380–#396:** the private `deskree-inc/oby` API was unreachable here (`gh` unauthenticated). Each issue is mapped in its own row from local branch evidence; **titles/bodies were not loaded**.

| Issue | Branch tip | Unique commits vs `origin/dev` | Title |
| --- | --- | --- | --- |
| #380 | `oby/build-380` @ `5be2319` | 0 (tip = Claude Code UX research commit for #384) | *unavailable* |
| #381 | `oby/build-381` @ `44fa779` | 13 (activity stream) | *unavailable* — in-repo: “activity list” (`Engine/ACP.swift:215`, `docs/cursor.md:96`) |
| #382 | `oby/build-382` @ `e9309f8` | 0 (tip already on `dev`: rebase/base-test fix) | *unavailable* |
| #383 | *(no local branch)* | — | *unavailable* |
| #384 | *(no local branch)* | — | *unavailable* (research landed as `5be2319` / `docs/research/claude-code-parity.md`) |
| #385 | *(no local branch)* | — | *unavailable* |
| #386 | `oby/build-386` @ `005d864` | 0 | *unavailable* |
| #387 | `oby/build-387` @ `005d864` | 0 | *unavailable* |
| #388 | `oby/build-388` @ `005d864` | 0 | *unavailable* |
| #389 | `oby/build-389` @ `005d864` | 0 | *unavailable* |
| #390 | `oby/build-390` @ `005d864` | 0 | *unavailable* |
| #391 | `oby/build-391` @ `005d864` | 0 | *unavailable* |
| #392 | *(no local branch)* | — | *unavailable* |
| #393 | `oby/build-393` @ `0ffbfda` | 11 (attachments) | *unavailable* — job `2138467c` |
| #394 | `oby/build-394` @ `005d864` | 0 | *unavailable* |
| #395 | `oby/build-395` @ `005d864` | 0 | *unavailable* |
| #396 | `oby/build-396` @ `005d864` | 0 | *unavailable* |

---

## Product shapes (one paragraph)

OpenMausBot is a **messaging app of bots**: each sidebar contact is a local Claude/Codex/Grok/ACP agent with its own model, computer, apps, memory, routines and approval level (`README.md:11–13`). Oby is a **coding dispatcher in the notch**: one owner conversation, jobs with git worktrees, reviews, Mac checks and merge into `dev` (`Engine/Jobs.swift:18`, `Engine/Pipeline.swift:46–58`). Steal harness discipline from MausBot; do not copy the multi-bot chat product shape wholesale.

---

## Area comparison (with citations)

Citations use `file:line` on **both** sides. OpenMausBot paths are relative to `/tmp/openmausbot-readonly/`. Oby paths are relative to this repository.

### 1. Agent runtime

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Contract | One `Assignment` lifecycle, one wake lane, SQLite + events (`docs/runtime-contract.md:9`, `:30`, `:97`) | Jobs in SQLite (`Engine/Jobs.swift:1918–1923`); derived stages (`Engine/Pipeline.swift:46–58`); no single typed assignment tree |
| Engines | Claude / Codex / Grok CLIs, custom ACP, OpenAI-compat (`docs/custom-engines.md:21–53`, `README.md:66–71`) | Claude stream-json; Codex `app-server` (`Engine/Codex.swift:6–8`, `:58–65`); Cursor ACP (`Engine/ACP.swift:75`, `:215`); proven notes in `AGENTS.md` |
| Admission | Pure `admit()` steer/queue/start/refuse (`server/admission.ts:1`, `:84–120`) | Accounts + file claims + `startWhen` (`Engine/Accounts.swift:340–347`, `Engine/StartWhen.swift:108`, `:186–190`) |
| Stall | `TurnWatchdog` silence window; human/computer waits excluded (`server/turn-watchdog.ts:1–9`, `:76–83`); runtime stall budgets (`docs/runtime-contract.md:85–91`) | 45‑minute round / 3‑hour job (`docs/runner-api.md:138`); Failures study stalls (`docs/runner-api.md:774`); no per-tool activity watchdog |
| Crash resume | Protocol-state class; no replay after accept (`server/resume-recovery.ts:16–24`); restart table + outward gate (`docs/runtime-contract.md:66–81`); ACP recovery e2e (`server/acp-recovery.e2e.test.ts:9`) | `Restarts` journal (`Engine/Restarts.swift:12–17`); `resumeAfterRestart()` (`Engine/Restarts.swift:99`); at most two pickups / 30 min (`:12–13`) |
| Engine failover | Capability-checked automatic recovery (`server/automatic-recovery.ts:6–15`) | Limit mid-round → next account/tool (`docs/runner-api.md:113`) |

**Gap:** Oby’s resume and clocks are strong for coding jobs; MausBot’s **pure admission + stall-without-progress + outward-action-aware restart** are sharper and heavily tested.

### 2. Approvals / fatigue

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Levels | Ask / Auto-accept edits / Approve for me / Full / Custom; default **Full** (`docs/approval-levels.md:11–26`) | Ask / Accept edits / Plan / **Bypass** (default) (`Engine/Permissions.swift:13–21`, `:425–428`) |
| Auto path | Explicit grants only: Full, saved command, MCP read allowlist, narrow web-search (`server/auto-approve.ts:89–114`); questions never auto-answered (`:62`, `:101–103`) | Policy denials → saved rules → mode (`Engine/Permissions.swift:120–144`); quiet reads never ask (`:108`) |
| Agent-tool policy | Built-in agents MCP reads only via an allowlisted name set + annotations — never third-party `readOnlyHint` alone (`server/agent-tool-policy.ts:1–29`; mirrored in `docs/approval-levels.md:231–243`) | Among MCP tools, agents may call only Tetrix’s graph reads + `save_session` (`docs/runner-api.md:164`); vault connected apps brokered as job-scoped `oby` MCP (`Engine/Connected.swift:3–8`, `:17–26`) |
| Delegation | Chief level flows down, capped by engine (`docs/approval-levels.md:85–109`, `server/auto-approve.ts:37–58`) | Lead starts jobs (`Engine/Lead.swift`); no per-bot approval inheritance |
| Fatigue tactics | Full/Auto so native reviewers absorb noise; remembered exact grants; expired asks never re-carded (`docs/approval-levels.md:78–79`); outbound always held (`server/auto-approve.ts:107`) | Bypass default; “Always in this repo”; inbox for permissions (`Engine/Inbox.swift:32`, `:174–176`) |

**Gap:** Same spirit (don’t nag for safe work). MausBot’s **logged verdict sources**, **Chief level inheritance**, and **explicit read-only agent-tool allowlist** (`server/agent-tool-policy.ts`) are clearer. Oby already avoids Claude’s own bypass flag so Policy still holds (`Engine/Permissions.swift:11–12`) — keep that; don’t copy MausBot Full as a product default for coding publish.

### 3. Routing and accounts

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Multi-account | Per-engine homes; plan usage report (`server/plan-usage.ts:1–56`); Composio multi-account labels (`docs/composio.md:1–14`) | `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `CURSOR_CONFIG_DIR` (`Engine/Accounts.swift:10–14`, `:489–491`); `fullUntil`, 80% weekly reserve, 95% hard ceiling (`Engine/Accounts.swift:50–71`, `:340–347`) |
| Decision model | Jev/OpenRouter room routing, fail-open (`docs/decision-model.md:1–79`) | Brain (Haiku) + Lead (Sonnet); no calibrated classifier (`Engine/Brain.swift`, `Engine/Lead.swift`) |
| Tool selection | Allow/exclude MCP/native selectors (`docs/tool-selection.md:1–18`) | Job-scoped `oby` MCP broker for vault apps (`docs/mcp.md:1–3`, `docs/research/claude-code-parity.md:13`) |

**Live pain:** Claude weekly 95–98% and Codex 5‑hour at 100% sit on Oby’s `nearlyFull = 0.95` and `fullUntil` paths (`Engine/Accounts.swift:53–71`). Jobs then show “Waiting for an account with room” (`Engine/Review.swift:217`) while other work still burns quota (reviews up to 3 + escalation + security: `Engine/Review.swift:76–78`, `docs/runner-api.md:222–224`). This branch’s `mayUseReserve` / `allowReserved` (`Engine/Review.swift:135–156`, `:777–780`) starts that quota-aware admission for first reviews.

### 4. Memory, routines, proactivity, incidents

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Memory | Per-bot `MEMORY.md` + topics, budget, recall, redaction (`docs/memory.md:1–96`, `:42–70`) | No product memory; Tetrix for graph/sessions; Claude Code parity lists memory as already-filed (`docs/research/claude-code-parity.md:21`) |
| Routines | Cron/interval, catch-up ≤12h, keep-awake (`docs/routine-schedules.md:1–74`) | `startWhen` one-shots (`Engine/StartWhen.swift:7–13`, `:108–112`) — not recurring |
| Proactivity | Explicit triggers only — Auto / routine / webhook (`docs/notification-and-proactivity-qa.md:1–7`) | Jobs + Lead events; no heartbeat inventing work (aligned) |
| Incidents | Chief “Team incidents” thread, retry caps, mute storms (`docs/team-incidents.md:1–51`) | Inbox + Failures self-heal (`Engine/Failures.swift`, `Engine/Inbox.swift`); no coordinator bot for stalled teammates |

### 5. Phone / remote

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Phone | Native companion + PWA; QR pair; SSE; approvals (`docs/ios-companion.md:1–60`, `docs/phone-web-app.md:1–16`) | Native iPhone/Watch; shared conversation; push path |
| Remote | Cloudflare tunnel / Tailscale / self-host; loopback trust warnings (`docs/self-hosting.md:7–14`, `SECURITY.md:16–26`) | Control plane patterned on MausBot (`docs/remote-access.md:1–7`); LAN gateway on `dev`; E2E and Mac-awake still roadmap (`docs/remote-access.md:83–86`) |
| Voice | Call mode, spoken approvals, TTS (`docs/voice-mode.md:47–76`) | Hold-to-talk / tap draft rules (`AGENTS.md`); local STT on runner |

**Skip** copying MausBot’s chat-shaped companion UX; **keep** aligning remote security with their documented default-deny pairing (Oby already cites them at `docs/remote-access.md:3`).

### 6. Extensibility

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Custom engines | `customAcp` + openai-compat instances (`docs/custom-engines.md:21–76`) | Fixed Claude/Codex/Cursor (Gemini later) |
| Custom MCP | UI + OAuth + Test (`docs/custom-mcp-servers.md:1–16`) | Vault-backed connected apps as job MCP (`Engine/Connected.swift:3–8`); not arbitrary user MCP UI |
| Composio | 500+ apps marketplace (`docs/composio.md:1–14`) | F17 connected apps (own broker) (`Engine/Connected.swift:3`) |
| Skills / presets | Skill library, presets without widening authority (`docs/presets.md:15–30`) | Agents’ own skills; no Oby preset catalog |

### 7. Quality / release cadence

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Tests | Large Vitest + e2e under `server/`; runtime invariant suite (`docs/runtime-contract.md:93–109`) | Swift tests (`RunnerTests`, `MacTests`, …); GitHub Actions Linux + Apple (`docs/ci.md:7–8`) |
| Evals | Hermetic harness evals (scripted engines), golden replay, opt-in live (`evals/README.md:1–24`) | Lead-turn spike eval (`spikes/lead-turn/`); no harness eval suite |
| Releases | Aggressive patch train; CI selection + release-only-on-green (`docs/ci.md:36–42`, `docs/releasing.md:25–32`) | Feature-gated `dev`→`main`; Mac check before merge; no public release mill |

---

## Live pain points × MausBot lessons

1. **3–4 review jobs per PR; one re-ran with no new commits**  
   Oby: up to 3 reviews + escalation 4th + optional security (`Engine/Review.swift:76–78`, `docs/runner-api.md:222–224`). Follow-ups should skip when the patch is unchanged (`Engine/Checks.swift` / `Rebase.samePatch`). MausBot: no analogous multi-agent PR mill — **do better on Oby’s own pipeline**.

2. **`done` while stage says “Waiting for a Mac check” / “Waiting for an account with room”**  
   Author job `status == .done` while `mergeProgress` still shows Mac wait (`Engine/Checks.swift:1254–1260`) or while routing waits (`Engine/Review.swift:217`). MausBot’s lifecycle never calls that “completed” (`docs/runtime-contract.md:30–34`). **Do better:** one honest lifecycle to the UI.

3. **Job `2138467c` “NEEDS YOU” with empty inbox**  
   Was: `needsYou` included `canPublish`/`stranded` (`Engine/Jobs.swift:263–286`) without inbox cards. **Fixed on this branch:** `InboxItem.Kind.publish` + `Inbox.need` (`Engine/Inbox.swift:33–35`, `:207–219`). MausBot parks `needs_input` with a card (`docs/runtime-contract.md:39`).

4. **Claude 95–98% weekly / Codex 5‑hour 100%**  
   Hard stops at 95% (`Engine/Accounts.swift:53–71`) are correct; burning first reviews into the reserve was the product bug. **Partially fixed on this branch:** first reviews require unreserved room (`Engine/Review.swift:135–156`, `:777–780`).

---

## Roadmap map (#380–#396)

Each issue is its own row. Where the GitHub title is unavailable and there are no unique commits, **no recommendation is invented** — the fit is left open until `gh` can load the body. Only rows with local evidence get a best-fit.

| Issue | Evidence | Best-fit recommendation | Notes |
| --- | --- | --- | --- |
| #380 | `oby/build-380` @ `5be2319` (same tip as #384 research commit); 0 unique commits | Open — likely a follow-on to `docs/research/claude-code-parity.md` (overlap with recs **7–9**) | Title unavailable; do not assign until body loads |
| #381 | Unique commits: activity stream; `Engine/ACP.swift:215`, `docs/cursor.md:96` | Finish activity stream; keep Oby’s job-step model (related to rec **1** stall ticks once activity lands) | Highest-confidence local proxy: “activity list” |
| #382 | Tip `e9309f8` already on `dev` (rebase/base-test fix); 0 unique commits | Open — no MausBot steal implied by tip | Title unavailable |
| #383 | No local `oby/build-383` | Open | Title unavailable; no local evidence |
| #384 | No local branch; research file present as `docs/research/claude-code-parity.md` | Claude Code UX gaps inventory (sibling research to this doc); memory/routines/extensions overlap recs **7–9** | Title unavailable from `gh`; file is the deliverable |
| #385 | No local `oby/build-385` | Open | Title unavailable; no local evidence |
| #386 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #387 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #388 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #389 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #390 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #391 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #392 | No local `oby/build-392` | Open | Title unavailable; no local evidence |
| #393 | Unique commits: Mac/iPhone attachments; job `2138467c` | Finish attachments; Needs-you/inbox fix already on this branch (rec **2**) | Highest-confidence from commits |
| #394 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #395 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |
| #396 | Tip `005d864`; 0 unique commits | Open | Title unavailable; parked tip only |

When `gh` can read issue bodies, replace each “Open” row with the issue’s own title and Build list; do not invent titles here.

---

## Ranked recommendations (≤12)

Effort: S &lt; 1 week · M 1–3 weeks · L multi-milestone. Impact: on today’s coding-dispatcher pain and roadmap leverage.

### 1. Steal — Assignment-style lifecycle + stall detection — **Impact: High · Effort: L**

- **MausBot:** One record, budgets, stall on no durable progress, restart rules including outward actions (`docs/runtime-contract.md:27–91`, `server/turn-watchdog.ts:76–83`).
- **Oby:** Jobs + stages + Restarts (`Engine/Restarts.swift:99`, `Engine/Pipeline.swift:46–58`); clocks but no activity stall.
- **Gap:** Waiting/done/needs-you disagree; silent wedged agents.
- **Do:** Documented job lifecycle contract with stall ticks from agent events once #381 lands; never label Done while Mac check / account wait is the real stage.

### 2. Do better — Needs you ⇔ inbox invariant — **Impact: High · Effort: S** *(landed on this branch)*

- **MausBot:** `needs_input` always has a card (`docs/runtime-contract.md:39`).
- **Oby (before):** `needsYou` ⊃ inbox kinds (`Engine/Jobs.swift:284–286` vs old `Inbox.need`).
- **Oby (now):** `InboxItem.Kind.publish` (`Engine/Inbox.swift:33–35`, `:207–219`).
- **Gap:** Keep the invariant tested; extend if new `needsYou` reasons appear.
- **Do:** Maintain the Swift tests added with this fix.

### 3. Do better — Quota-aware review / pipeline admission — **Impact: High · Effort: M** *(partially landed)*

- **MausBot:** Admission surfaces + spend awareness (`server/admission.ts:84–120`, plan usage).
- **Oby:** Reserve/nearlyFull (`Engine/Accounts.swift:50–71`); first reviews now skip reserve (`Engine/Review.swift:135–156`, `:777–780`).
- **Gap:** Empty re-reviews; Done + “Waiting for room” UI; security/escalation still spend when near ceiling.
- **Do:** Never start a review with empty `range-diff`/no new commits; show one waiting stage, not Done + waiting.

### 4. Steal — Pure admission function + golden tests — **Impact: Medium · Effort: M**

- **MausBot:** IO-free `admit()` + golden tests (`server/admission.ts:1–2`, `server/admission-golden.test.ts`).
- **Oby:** Routing in StartWhen / Review / Move (`Engine/Accounts.swift:340`, `Engine/StartWhen.swift:186–190`).
- **Gap:** Hard to prove busy / reserve / Mac-offline decisions.
- **Do:** Extract choose + review/start gates into a pure decision type with table tests.

### 5. Steal — Harness evals (scripted engines) — **Impact: High · Effort: M**

- **MausBot:** `evals/` hermetic scenarios (`evals/README.md:1–14`).
- **Oby:** Unit/integration tests; one Lead spike eval (`spikes/lead-turn/`).
- **Gap:** Pipeline bugs regress without scenarios.
- **Do:** Tiny eval/scenario suite: restart mid-permission, account full mid-review, needsYou⇒inbox, unchanged-patch no re-review.

### 6. Steal — Incident coordinator path (Lead-sized) — **Impact: Medium · Effort: M**

- **MausBot:** Team incidents → Chief retry/reassign with caps (`docs/team-incidents.md:9–51`).
- **Oby:** Inbox + Failures; Lead for vague goals.
- **Gap:** Stalls wait for a human to notice.
- **Do:** Wake Lead/Failures with a typed report (data, not instructions), capped retries.

### 7. Steal (thin) — Bot/owner memory with budget — **Impact: Medium · Effort: L**

- **MausBot:** Budgeted `MEMORY.md`, redaction, recall (`docs/memory.md:42–96`).
- **Oby:** None productized; Tetrix graph.
- **Gap:** Brain/Lead re-learn preferences every turn.
- **Do:** One owner memory with line/byte budget and secret redaction.

### 8. Steal (later) — Recurring routines — **Impact: Medium · Effort: L**

- **MausBot:** Cron + catch-up (`docs/routine-schedules.md:1–74`).
- **Oby:** `startWhen` only (`Engine/StartWhen.swift:7–13`, `:108–112`).
- **Gap:** Recurring maintenance needs a human.
- **Do:** After memory; keep explicit-trigger proactivity (`docs/notification-and-proactivity-qa.md:1–7`).

### 9. Do better / partial steal — Extension catalog on F17 — **Impact: Medium · Effort: L**

- **MausBot:** Custom MCP UI, Composio, presets (`docs/custom-mcp-servers.md:1–16`, `docs/composio.md:1–14`, `docs/presets.md:15–30`); read-only agent tools allowlisted (`server/agent-tool-policy.ts:3–29`).
- **Oby:** Vault MCP broker (`Engine/Connected.swift:3–8`); parity draft #3 (`docs/research/claude-code-parity.md:62–78`).
- **Gap:** Portable workflows.
- **Do:** Commands/skills catalog on the existing broker; **skip** Composio marketplace unless Connected apps explicitly need it; keep an allowlisted read-only surface like `agent-tool-policy.ts`.

### 10. Steal — Resume failure classification — **Impact: Medium · Effort: S–M**

- **MausBot:** `before-accept` vs `after-accept` (`server/resume-recovery.ts:16–24`).
- **Oby:** Always re-prompt with notice (`Engine/Restarts.swift:16–17`, `:99`).
- **Gap:** Risk of double side effects after crash.
- **Do:** Classify whether the cut turn already published/pushed; skip blind replay (`docs/runtime-contract.md:73–74`).

### 11. Skip — Multi-bot chat roster / Boat computers / Composio-as-core — **Impact: Low for Oby’s coding dispatcher · Effort: L (if forced)**

- **MausBot:** Product center is a bot roster with computers (`README.md:11–13`, `:71`, `:111`).
- **Oby:** Center is git jobs + notch (`Engine/Jobs.swift:18`, `Engine/Pipeline.swift:46–58`).
- **Gap:** Wrong product shape for Oby’s F-order roadmap.
- **Why skip:** Cloud computers and a 500-app marketplace dilute coding-dispatcher milestones; F17 already covers vault-backed connections without Composio-as-core.

### 12. Skip — Matching 100+ releases / 2 months — **Impact: Low (harmful if chased) · Effort: L (CI/release re-architecture)**

- **MausBot:** Shard balancer + release-only-on-green train (`docs/ci.md:36–42`, `docs/releasing.md:25–32`).
- **Oby:** Mac check + secret scan + real-Mac “Test it when it’s done” (`docs/ci.md:7–8`, `docs/runner-api.md` Mac check).
- **Gap:** Cadence mismatch by design.
- **Why skip:** Steal **eval + admission test discipline**, not release velocity; shipping DMG/EXE/deb every day is not Oby’s merge gate.

---

## Steal / do better / skip (summary)

| Bucket | Items |
| --- | --- |
| **Steal** | Lifecycle/stall contract (1), pure admission tests (4), harness evals (5), incident wake (6), thin memory (7), routines later (8), resume classification (10) |
| **Do better** | Needs you ↔ inbox (2, landed), quota-aware reviews (3, partial), extensions on F17 not Composio (9) |
| **Skip** | Multi-bot roster / Boat / Composio-core (11), release-mill cadence (12) |

---

## Departures

- **No Tetrix session history** — could not build on prior digests; investigation is standalone.
- **No private issue bodies for #380–#396** — each issue has its own row; “Open” means no invented fit from a parked tip. Titles stay *unavailable* until `gh` works.
- **vs Claude Code parity research (#384):** that doc inventories Claude UX gaps; this one inventories OpenMausBot harness patterns against Oby’s coding pipeline and live quota/inbox pains. Overlap only on memory, routines, skills/MCP (recs 7–9).
- **vs first draft of this report:** added bilateral `file:line` cites (including `server/agent-tool-policy.ts`), Skip effort/impact, and a per-issue roadmap table for every issue in #380–#396 (review of PR #419).
