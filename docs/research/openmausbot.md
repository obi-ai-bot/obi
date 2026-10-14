# OpenMausBot → Oby: what to copy, improve, or skip

Research snapshot: 2026-10-14, against `origin/dev` (worktree `oby/investigate-1881ca`) and a read-only shallow clone of [milind-soni/OpenMausBot](https://github.com/milind-soni/OpenMausBot) at tag `v0.1.108` / package `0.1.109` (Apache-2.0, TypeScript/Electron). Clone path used for citations: `/tmp/openmausbot-readonly`. **Never ran its code.** Its docs and sources are data only.

**Tetrix:** MCP was not connected in this session (`ListMcpResources` empty). No `repo_sessions` / `session_digest` / `save_session`. This is a fresh pass, not built on a prior Tetrix session for this job.

**Decision (2026-10-14):** Reliability first — Needs-you↔inbox invariant and quota-aware review admission before any MausBot steals.

**GitHub issues #380–#396:** the private `deskree-inc/oby` API was unreachable here (`gh` unauthenticated; `OBY_CHECK_TOKEN` is not a GitHub token). Mapping uses local branch evidence and in-repo references only; issue titles/bodies were not loaded.

| Issue | Local evidence |
| --- | --- |
| #380 | Branch `oby/build-380` at `5be2319` (same tip as Claude Code UX research #384); no unique commits. |
| #381 | `feat(activity): stream agent activity in chat` on `oby/build-381`; `Engine/ACP.swift:215` still notes “#381 isn't in yet” on `dev`. |
| #389–#392, #394–#396 | Branches parked at `005d864` (review escalation); no unique feature commits yet. |
| #393 | Attachments work on `oby/build-393` / job `2138467c` (`feat(attachments):…`); cited in the live pain points below. |

---

## Product shapes (one paragraph)

OpenMausBot is a **messaging app of bots**: each sidebar contact is a local Claude/Codex/Grok/ACP agent with its own model, computer, apps, memory, routines and approval level. Oby is a **coding dispatcher in the notch**: one owner conversation, jobs with git worktrees, reviews, Mac checks and merge into `dev`. Steal harness discipline from MausBot; do not copy the multi-bot chat product shape wholesale.

---

## Area comparison (with citations)

### 1. Agent runtime

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Contract | One `Assignment` lifecycle, one wake lane, SQLite + append-only events (`docs/runtime-contract.md:1–25`, `server/runtime/`). | Jobs in SQLite; pipeline stages; no single typed assignment tree. |
| Engines | Claude / Codex / Grok CLIs, custom ACP, OpenAI-compat (`docs/custom-engines.md:21–53`). | Claude stream-json, Codex app-server, Cursor ACP (`Engine/ACP.swift`, `Engine/Codex.swift`); proven notes in `AGENTS.md`. |
| Admission | Pure `admit()` for steer/queue/start/refuse by surface (`server/admission.ts:84–120`). | Capacity via accounts + file claims + `startWhen` (`Engine/StartWhen.swift`, `Engine/Accounts.swift:340`). |
| Stall | `TurnWatchdog` on silence; human/computer waits excluded (`server/turn-watchdog.ts:1–84`); runtime budgets + “no progress” continuations (`docs/runtime-contract.md:85–91`). | 45‑minute round / 3‑hour job clocks (`docs/runner-api.md:138`); Failures study stalls (`docs/runner-api.md:773`). No per-tool activity watchdog. |
| Crash resume | Protocol-state resume classification; no replay after accept (`server/resume-recovery.ts:1–44`); restart table for running/outward/waiting (`docs/runtime-contract.md:66–81`); ACP recovery e2e (`server/acp-recovery.e2e.test.ts`). | `Restarts` journal + `resumeAfterRestart()` (`Engine/Restarts.swift:10–19`, `93–129`); at most two pickups / 30 min then interrupted. |
| Engine failover | Capability-checked automatic recovery (`server/automatic-recovery.ts:6–15`). | Limit mid-round → next account/tool (`docs/runner-api.md:113`); brain failover Claude→Codex exists on `dev`. |

**Gap:** Oby’s resume and clocks are strong for coding jobs; MausBot’s **pure admission + stall-without-progress + outward-action-aware restart** are sharper and heavily tested.

### 2. Approvals / fatigue

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Levels | Ask / Auto-accept edits / Approve for me / Full / Custom; default **Full** (`docs/approval-levels.md:11–26`). | Ask / Accept edits / Plan / **Bypass** (default) (`Engine/Permissions.swift:13–21`, `427–428`). |
| Auto path | Explicit grants only: Full, saved command, MCP read allowlist, narrow web-search under Auto (`server/auto-approve.ts:89–115`). Questions never auto-answered (`:60–62`, `:101–103`). | Policy denials → saved rules → mode (`Engine/Permissions.swift:120–144`). Quiet reads never ask (`:107–108`). |
| Delegation | Chief level flows down, capped by engine (`docs/approval-levels.md:85–109`, `server/auto-approve.ts:37–58`). | Lead starts jobs; no per-bot approval inheritance. |
| Fatigue tactics | Full/Auto so native reviewers absorb noise; remembered exact grants; expired asks never re-carded (`docs/approval-levels.md:78–79`); outbound always held (`server/auto-approve.ts:107`). | Bypass default; “Always in this repo”; inbox for permissions (`Engine/Inbox.swift:31–32`). |

**Gap:** Same spirit (don’t nag for safe work). MausBot’s **logged verdict sources** and **Chief level inheritance** are clearer. Oby already avoids Claude’s own bypass flag so Policy still holds (`Engine/Permissions.swift:11–12`) — keep that; don’t copy MausBot Full as a product default for coding publish.

### 3. Routing and accounts

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Multi-account | Per-engine homes; plan usage report (`server/plan-usage.ts:1–56`); Composio multi-account labels (`docs/composio.md:1–14`). | `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / Cursor homes (`Engine/Accounts.swift:4–18`); `fullUntil`, 80% weekly reserve, 95% hard ceiling (`:50–71`, `:340–346`). |
| Decision model | Jev/OpenRouter room routing, fail-open (`docs/decision-model.md:1–79`). | Brain (Haiku) + Lead (Sonnet); no calibrated classifier. |
| Tool selection | Allow/exclude MCP/native selectors (`docs/tool-selection.md:1–18`). | Job-scoped `oby` MCP broker for vault apps (`docs/mcp.md`, `docs/research/claude-code-parity.md:13`). |

**Live pain:** Claude weekly 95–98% and Codex 5‑hour at 100% sit on Oby’s `nearlyFull = 0.95` and `fullUntil` paths (`Engine/Accounts.swift:53–71`). Jobs then show “Waiting for an account with room” (`Engine/Review.swift:203–204`) while other work still burns quota (reviews up to 3 + escalation + security review: `Engine/Review.swift:76–78`, `docs/runner-api.md:222–224`).

### 4. Memory, routines, proactivity, incidents

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Memory | Per-bot `MEMORY.md` + topics, budget, recall, redaction (`docs/memory.md:1–96`). | No product memory; Tetrix for graph/sessions; Claude Code parity draft lists memory as already-filed (`docs/research/claude-code-parity.md:21`). |
| Routines | Cron/interval, catch-up ≤12h, keep-awake (`docs/routine-schedules.md:1–74`). | `startWhen` one-shots (`Engine/StartWhen.swift`), not recurring. |
| Proactivity | Explicit triggers only — Auto / routine / webhook (`docs/notification-and-proactivity-qa.md:1–7`). | Jobs + Lead events; no heartbeat inventing work (aligned). |
| Incidents | Chief “Team incidents” thread, retry caps, mute storms (`docs/team-incidents.md:1–51`). | Inbox + Failures self-heal (`Engine/Failures.swift`, `Engine/Inbox.swift`); no coordinator bot for stalled teammates. |

### 5. Phone / remote

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Phone | Native companion + PWA; QR pair; SSE; approvals on phone (`docs/ios-companion.md:1–60`, `docs/phone-web-app.md`). | Native iPhone/Watch; shared conversation; push path. |
| Remote | Cloudflare tunnel / Tailscale / self-host; guardian gateway; loopback trust warnings (`docs/self-hosting.md:7–14`, `SECURITY.md:16–26`). | Control plane patterned on MausBot (`docs/remote-access.md:1–7`); LAN gateway on `dev`; E2E and Mac-awake still roadmap (`docs/remote-access.md:83–86`). |
| Voice | Call mode, spoken approvals, TTS providers (`docs/voice-mode.md`). | Hold-to-talk / tap draft rules (`AGENTS.md`); local STT on runner. |

**Skip** copying MausBot’s chat-shaped companion UX; **keep** aligning remote security with their documented default-deny pairing (Oby already cites them).

### 6. Extensibility

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Custom engines | `customAcp` + openai-compat instances (`docs/custom-engines.md`). | Fixed Claude/Codex/Cursor (Gemini later). |
| Custom MCP | UI + OAuth + Test (`docs/custom-mcp-servers.md:1–16`). | Vault-backed connected apps as job MCP; not arbitrary user MCP UI. |
| Composio | 500+ apps marketplace (`docs/composio.md`). | F17 connected apps (own broker). |
| Skills / presets | Skill library, presets without widening authority (`docs/presets.md:15–30`). | Agents’ own skills; no Oby preset catalog. |

### 7. Quality / release cadence

| | OpenMausBot | Oby today |
| --- | --- | --- |
| Tests | ~608 `*.test.ts` + ~131 e2e under `server/`; runtime invariant suite (`server/runtime/invariants.ts` via `docs/runtime-contract.md:93–109`). | Hundreds of Swift tests (`RunnerTests`, `MacTests`, …); GitHub Actions for Linux + Apple (`docs/ci.md`). |
| Evals | Hermetic harness evals (scripted engines), golden replay, opt-in live (`evals/README.md:1–24`). | Lead-turn spike eval (`spikes/lead-turn/`); no harness eval suite. |
| Releases | ~58 desktop `v0.1.*` tags from 2026-09-01→2026-10-13 (~41 days); package at `0.1.109`; repo since 2026-08-11. User’s “108 in ~2 months” matches the aggressive patch cadence if counting all tags/channels. CI selection + release-only-on-green CI (`docs/ci.md`, `docs/releasing.md:25–32`). | Feature-gated `dev`→`main`; Mac check before merge; no public release mill. |

---

## Live pain points × MausBot lessons

1. **3–4 review jobs per PR; one re-ran with no new commits**  
   Oby: up to 3 reviews + escalation 4th + optional security review (`Engine/Review.swift:76–78`, `docs/runner-api.md:222`). Follow-ups are supposed to skip when the patch is unchanged (`docs/runner-api.md` rebase/`range-diff` path). MausBot: no analogous multi-agent PR mill — **do better on Oby’s own pipeline** (dedupe review starts; don’t spend quota on empty re-reviews).

2. **`done` while stage says “Waiting for a Mac check” / “Waiting for an account with room”**  
   By design today: author job `status == .done` while `mergeProgress` still shows Mac wait (`Engine/Checks.swift:1253–1260`) or while routing waits (`Engine/Review.swift:203–204`). MausBot’s single lifecycle status (`queued|running|waiting|needs_input|…`, `docs/runtime-contract.md:29–34`) never calls that “completed”. **Do better:** surface one honest lifecycle to the UI (e.g. not Done until merge/dismiss/fail).

3. **Job `2138467c` “NEEDS YOU” with empty inbox**  
   `Job.needsYou` includes `canPublish` and `stranded` (`Engine/Jobs.swift:284–286`), and Conversation groups those under Needs you (`Engine/Conversation.swift:95–102`). Inbox materialization covers permission/question/review/merge/cloud/failed — **not** `canPublish` / `stranded` (`Engine/Inbox.swift:170–211`). That mismatch produces Needs you with no card. MausBot parks `needs_input` with a real card (`docs/runtime-contract.md:39`). **Fix on Oby (high impact, medium effort).**

4. **Claude 95–98% weekly / Codex 5‑hour 100%**  
   Hard stops at 95% and `fullUntil` (`Engine/Accounts.swift:53–71`) are correct; burning 3–4 reviews + Mac-check fix loops while near the ceiling is the product bug. MausBot’s spend caps / plan usage are visibility; Oby needs **quota-aware review admission** (skip or defer non-escalation reviews when every account is ≥ reserve).

---

## Roadmap map (#380–#396)

Without issue bodies, map by theme to recommendations below:

| Issue | Best-fit recommendation |
| --- | --- |
| #381 (activity) | Aligns with MausBot’s spoken/activity narration idea; finish the in-flight activity stream — don’t rebuild as MausBot chips. |
| #393 (attachments) | Finish; unrelated to MausBot steal list except phone parity. Also the live Needs-you/inbox bug candidate. |
| #380, #389–#392, #394–#396 | Parked branches — when titles load, assign: memory/routines → recs 7–8; skills/MCP → rec 9; incidents/proactivity → rec 6; evals → rec 5. |

---

## Ranked recommendations (≤12)

Effort: S &lt; 1 week · M 1–3 weeks · L multi-milestone. Impact: on today’s coding-dispatcher pain and roadmap leverage.

### 1. Steal — Assignment-style lifecycle + stall detection — **Impact: High · Effort: L**

- **MausBot:** One record, budgets, stall on no durable progress, restart rules including outward actions (`docs/runtime-contract.md:27–91`, `server/turn-watchdog.ts:76–83`).
- **Oby:** Jobs + stages + Restarts (`Engine/Restarts.swift:93–129`); clocks but no activity stall.
- **Gap:** Waiting/done/needs-you disagree; silent wedged agents.
- **Do:** Introduce a documented job lifecycle contract (even if still one SQLite jobs table) with stall ticks from agent events once #381 lands; never label `done` while Mac check / account wait is the real stage.

### 2. Do better — Needs you ⇔ inbox invariant — **Impact: High · Effort: S**

- **MausBot:** `needs_input` always has a card (`docs/runtime-contract.md:39`).
- **Oby:** `needsYou` ⊃ inbox kinds (`Engine/Jobs.swift:284–286` vs `Engine/Inbox.swift:170–211`).
- **Gap:** Job `2138467c`-class ghosts.
- **Do:** Every `needsYou` reason emits an open inbox item (or Needs you clears). Add a Swift test. Prefer this before more UI chrome.

### 3. Do better — Quota-aware review / pipeline admission — **Impact: High · Effort: M**

- **MausBot:** Admission surfaces + spend awareness (`server/admission.ts:84–120`, plan usage).
- **Oby:** Reserve/nearlyFull (`Engine/Accounts.swift:50–71`); still schedules up to 4 reviews + security (`Engine/Review.swift:76–78`).
- **Gap:** 3–4 review jobs and re-runs while Claude/Codex are empty.
- **Do:** Defer non-escalation reviews when no unreserved account; never start a review with empty `range-diff`/no new commits; show one “Waiting for room” job, not a Done + waiting stage.

### 4. Steal — Pure admission function + golden tests — **Impact: Medium · Effort: M**

- **MausBot:** IO-free `admit()` + golden tests (`server/admission.ts:1–2`, `admission-golden.test.ts`).
- **Oby:** Routing scattered across StartWhen / Review / Move.
- **Gap:** Hard to prove “busy / reserve / Mac offline” decisions.
- **Do:** Extract `AccountStore.choose` + review/start gates into a pure decision type with table tests (MausBot pattern, Oby rules).

### 5. Steal — Harness evals (scripted engines) — **Impact: High · Effort: M**

- **MausBot:** `evals/` hermetic scenarios; evaluate harness not models (`evals/README.md:1–14`).
- **Oby:** Unit/integration tests; one Lead spike eval.
- **Gap:** Pipeline bugs (review loops, inbox, resume) regress without a scenario suite.
- **Do:** Tiny `evals/` (or RunnerTests scenarios) for: restart mid-permission, account full mid-review, needsYou⇒inbox, unchanged-patch no re-review.

### 6. Steal — Incident coordinator path (Lead-sized) — **Impact: Medium · Effort: M**

- **MausBot:** Team incidents → Chief retry/reassign with caps (`docs/team-incidents.md:9–51`).
- **Oby:** Inbox + Failures; Lead for vague goals.
- **Gap:** Stalls wait for a human to notice.
- **Do:** When a job stalls/fails with a known class, wake Lead (or Failures) with a typed report (data, not instructions), capped retries — not a second chat product.

### 7. Steal (thin) — Bot/owner memory with budget — **Impact: Medium · Effort: L**

- **MausBot:** Budgeted `MEMORY.md`, redaction, recall (`docs/memory.md:42–96`).
- **Oby:** None productized; Tetrix graph.
- **Gap:** Brain/Lead re-learn owner preferences every turn.
- **Do:** One owner `MEMORY.md` (or Tetrix profile) with line/byte budget and secret redaction — not per-agent chat memory.

### 8. Steal (later) — Recurring routines — **Impact: Medium · Effort: L**

- **MausBot:** Cron + catch-up (`docs/routine-schedules.md`).
- **Oby:** `startWhen` only.
- **Gap:** “Every Monday run the audit” needs a human.
- **Do:** After memory; keep explicit-trigger proactivity (`docs/notification-and-proactivity-qa.md:1–7`).

### 9. Do better / partial steal — Extension catalog on F17 — **Impact: Medium · Effort: L**

- **MausBot:** Custom MCP UI, Composio, presets (`docs/custom-mcp-servers.md`, `docs/composio.md`, `docs/presets.md`).
- **Oby:** Vault MCP broker; parity draft #3 (`docs/research/claude-code-parity.md:62–78`).
- **Gap:** Portable workflows.
- **Do:** Commands/skills catalog on the existing broker; **skip** Composio marketplace unless Connected apps explicitly need it.

### 10. Steal — Resume failure classification — **Impact: Medium · Effort: S–M**

- **MausBot:** `before-accept` vs `after-accept` replay rules (`server/resume-recovery.ts:16–24`).
- **Oby:** Always re-prompt with notice (`Engine/Restarts.swift:15–17`).
- **Gap:** Risk of double side effects on publish/outbound after crash.
- **Do:** Classify whether the cut turn already published/pushed; skip blind replay (MausBot outward port, `docs/runtime-contract.md:73–74`).

### 11. Skip — Multi-bot chat roster / Boat computers / Composio-as-core

- MausBot’s product center (`README.md:11–13`, computer panel). Oby’s center is git jobs + notch. Cloud computers and 500-app marketplace dilute F-order roadmap.

### 12. Skip — Matching 100+ releases / 2 months

- Their CI shard balancer and release train (`docs/ci.md:30–42`, `docs/releasing.md`) fit a chat client shipping DMG/EXE/deb. Oby’s Mac-check + secret-scan + real-Mac “Test it when it’s done” gate is the right slower cadence. Steal **eval + admission test discipline**, not release velocity.

---

## Steal / do better / skip (summary)

| Bucket | Items |
| --- | --- |
| **Steal** | Lifecycle/stall contract (1), pure admission tests (4), harness evals (5), incident wake (6), thin memory (7), routines later (8), resume classification (10) |
| **Do better** | Needs you ↔ inbox (2), quota-aware reviews (3), extensions on F17 not Composio (9) |
| **Skip** | Multi-bot roster / Boat / Composio-core (11), release-mill cadence (12) |

---

## Departures

- **No Tetrix session history** — could not build on prior digests; investigation is standalone.
- **No private issue bodies for #380–#396** — roadmap map is branch-evidence only; fill titles when `gh` works.
- **vs Claude Code parity research (#384):** that doc inventories Claude UX gaps; this one inventories OpenMausBot harness patterns against Oby’s coding pipeline and live quota/inbox pains. Overlap only on memory, routines, skills/MCP (recs 7–9).
