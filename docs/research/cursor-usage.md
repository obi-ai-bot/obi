# Cursor account usage and limits for Oby

Research snapshot: 2026-10-14, against `origin/dev`, cursor-agent `2026.10.12-d47ca18` on this runner.
Deep research only — no Engine changes in this note. Tetrix MCP was not connected for this job, so there is no prior Tetrix session graph to build on; findings below are from public docs, forum posts, the CLI help surface, and Oby's code.

**Question:** How can Oby show a Cursor account's usage and limits (like Claude Code's 5-hour / weekly bars and Codex's rate limits) so routing stops treating Cursor as "reports no usage"?

**Short answer:** There is no official, individual-Pro way today to read Cursor *account* quota the way Claude Code and Codex expose windows. Cursor's product shape is also different: monthly dual pools on the Spending dashboard, not 5-hour / 7-day bars. The shippable next step is stronger limit-hit → `fullUntil` handling (like Codex). Bars and pace-based routing for Cursor need either Cursor to ship a CLI/ACP quota surface, or an opt-in Team/Enterprise Admin API path that does not help solo Pro.

## What Oby does today

| Surface | Behavior | Source |
| --- | --- | --- |
| Routing | Cursor is hard-coded as a tool that does not report usage; automatic work takes it last (tier 5), reason `Cursor reports no usage: fewest jobs running` | [`AccountStore.reportsUsage`](https://github.com/deskree-inc/oby/blob/dev/Engine/Accounts.swift#L474), [`choose`](https://github.com/deskree-inc/oby/blob/dev/Engine/Accounts.swift#L352), [runner-api Routing](https://github.com/deskree-inc/oby/blob/dev/docs/runner-api.md#L373) |
| Settings card | `fiveHour` / `sevenDay` stay null; card says Cursor reports no usage | [runner-api Account](https://github.com/deskree-inc/oby/blob/dev/docs/runner-api.md#L363), [`Usage.Snapshot`](https://github.com/deskree-inc/oby/blob/dev/Shared/Usage.swift#L24) |
| Sign-in label | `cursor-agent status` / models proxy; plan tier from `about` is not wired into the label path yet | [`CursorStatus`](https://github.com/deskree-inc/oby/blob/dev/Engine/Cursor.swift#L125), [docs/cursor.md](https://github.com/deskree-inc/oby/blob/dev/docs/cursor.md) |
| Limit mid-job | ACP `session/prompt` JSON-RPC error matching `Limits.isLimit` → `.limit(resets: nil)` → account `fullUntil` for one hour when no reset parsed | [`ACP.failed`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift#L442), [`Limits`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift#L1134), [`Desk.moveOn`](https://github.com/deskree-inc/oby/blob/dev/Engine/Desk.swift#L2275) |
| Tokens / auth | Oby never reads Cursor login files; jobs use isolated `HOME` / `XDG_CONFIG_HOME` / `CURSOR_CONFIG_DIR` | [docs/cursor.md](https://github.com/deskree-inc/oby/blob/dev/docs/cursor.md#L16), [`CursorStatus.environment`](https://github.com/deskree-inc/oby/blob/dev/Engine/Cursor.swift#L138) |

Verified on this runner (2026-10-14), matching the user's probe notes:

- `cursor-agent about --format json` → `subscriptionTier` (e.g. `"Premium"`), CLI version, email — **no usage or limits**.
- `cursor-agent status --format json` → auth state and `userId` — **no usage or limits**.
- CLI help lists `about`, `status|whoami`, `login`, `logout`, `mcp`, … — **no `usage` / `limits` / `spend` command**.

---

## 1) Does Cursor's ACP send usage, credits, rate-limit or quota data?

### Agent Client Protocol (agentclientprotocol.com)

| Signal | What the protocol defines | Account quota? |
| --- | --- | --- |
| `session/update` + `sessionUpdate: "usage_update"` | Stabilized 2026-06-05: context-window `{used, size}` and optional cumulative session `{cost.amount, currency}` | **No.** RFD FAQ: *"Rate limits and quotas are separate concerns that could be addressed in a future RFD."* ([Session Context Size and Cost](https://agentclientprotocol.com/rfds/session-usage)) |
| End-turn `PromptResponse.usage` | Still a **draft** RFD (per-turn token accounting) | **No** account pools |
| `_meta` | Reserved extensibility; clients **MUST NOT** assume provider-specific keys ([schema](https://agentclientprotocol.com/protocol/v1/schema)) | Not a contract for quota |
| Errors / stop reasons | v2 draft mentions exhausted quota as a possible future structured stop; v1 has no standard rate-limit object | Unstable / future |

### Cursor's ACP implementation

| Observation | Source |
| --- | --- |
| Official Cursor ACP docs describe initialize → authenticate → session/new → session/prompt, permissions, and `cursor/*` extensions — **no usage, credits, or quota fields** | [Cursor ACP docs](https://cursor.com/docs/cli/acp) |
| Staff confirm ACP `session/prompt` returns only `stopReason`; per-turn token `usage` from `-p --output-format json` is **not** on ACP; no ETA | [Forum 2026-09-17](https://forum.cursor.com/t/cursor-agent-acp-never-reports-token-usage-over-acp-though-p-output-format-json-does/171923) |
| Separate request: emit ACP `usage_update` for context-window UI (Zed); Cursor CLI does not send it today; staff logged as feature request | [Forum](https://forum.cursor.com/t/cli-emit-acp-usage-update-so-clients-like-zed-can-show-a-context-window-indicator/165358) |
| Even if Cursor shipped `usage_update` / PromptResponse tokens, that is **session context / spend tokens**, not the dashboard's monthly included pools | ACP RFD scope above |

Oby's ACP client ignores unknown `sessionUpdate` variants (including any future `usage_update`) in [`ACPRPC.events`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift#L216). Limit errors are only detected via `Limits.isLimit` on the JSON-RPC error message ([`ACP.failed`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift#L442)).

**Verdict for (1):** No reliable account-quota channel on Cursor ACP today. Context/token usage is missing in Cursor's ACP and would not replace Claude-style windows anyway.

---

## 2) Official Cursor APIs (Admin / Analytics)

### Plan eligibility (resolved)

| Plan | Admin / Analytics usage APIs? | Evidence |
| --- | --- | --- |
| **Team** | **Yes** — team Admin API key from Dashboard → API Keys → Team tab (admin role) | [Teams dashboard](https://cursor.com/docs/account/teams/dashboard): *"All API endpoints are available on both Team and Enterprise plans, except for the AI Code Tracking API which requires Enterprise plan."*; staff (2026-07): programmatic usage is *"Team and Enterprise features"* and *"aren't available on Pro solo"* ([thread](https://forum.cursor.com/t/need-help-to-understand-how-usage-billing-works-underneath/164650/7)) |
| **Enterprise** | **Yes** (same usage endpoints; some *other* Admin writes, e.g. per-user spend-limit setters, are documented Enterprise-only) | Same dashboard page; [Admin API](https://cursor.com/docs/account/teams/admin-api) marks specific write endpoints *"Availability: Enterprise only"* |
| **Pro / Hobby / individual** | **No** | Staff: Pro solo has dashboard view only ([same thread](https://forum.cursor.com/t/need-help-to-understand-how-usage-billing-works-underneath/164650/7)); personal `crsr_` keys are for Cloud Agents, not `/teams/*` (staff: [Invalid Team API Key](https://forum.cursor.com/t/admin-api-key-returns-invalid-team-api-key-not-an-auth-encoding-issue-already-verified/173692)) |

**Docs conflict to ignore for usage:** the [APIs Overview](https://cursor.com/docs/api) availability column labels Admin / Analytics *"Enterprise teams"*, and its sample `403` body says *"Enterprise access required"*. That coarser table conflicts with the Teams dashboard carve-out (AI Code Tracking = Enterprise-only; other REST APIs = Team **and** Enterprise) and with staff wording. For Oby planning, treat **usage Admin/Analytics as Team + Enterprise**, not Enterprise-only, and not Pro.

Auth for the usage path: team Admin API key (`crsr_…`) as Basic-auth username, empty password; reads often need `read:*` or `admin:*` ([Admin API](https://cursor.com/docs/account/teams/admin-api), [APIs Overview](https://cursor.com/docs/api)).

| API | Endpoints (usage-related) | Who |
| --- | --- | --- |
| **Admin API** | `POST /teams/daily-usage-data`, `POST /teams/spend`, `POST /teams/filtered-usage-events`, … | **Team and Enterprise** (team-admin key) |
| **Analytics API** | Team / by-user analytics | **Team and Enterprise** |
| **AI Code Tracking API** | Commit-level AI attribution | **Enterprise only** (not needed for account bars) |
| **Cloud Agents API / SDKs** | Run agents | Broader plans — **not** usage dashboards |

Admin data shape (useful if Oby ever opts in for Team/Enterprise):

- **`/teams/spend`**: per-member spend for the current billing cycle (`spendCents`, limits).
- **`/teams/daily-usage-data`**: per-user per-day activity (requests, lines, Tab, …); poll ≤ hourly; not a live 5-hour bar.
- **`/teams/filtered-usage-events`**: per-event tokens / `chargedCents` / `requestsCosts`; sum to reconcile with dashboard.

**Individual Pro:** no documented API key path for the same numbers.

**Verdict for (2):** Official programmatic usage is available to **Team and Enterprise** via a team Admin API key. It is **not** a Pro/solo fix. (Whether those payloads can drive included-pool *remaining* bars is still unverified — see follow-ups.)

---

## 3) Dashboard / editor usage — reachable without scraping?

### What Cursor shows humans

From [Usage and limits](https://cursor.com/help/models-and-usage/usage-limits) and [Models & Pricing](https://cursor.com/docs/account/pricing):

- Two **monthly** pools: **Cursor Models** (Grok / Composer family) and **Other Models** (third-party at API prices).
- Spending tab: real-time included usage, remaining allowance, on-demand charges; reset with the **billing cycle** (unused does not roll over).
- Hitting the included cap: editor notification; enable on-demand or upgrade. Auto / Router can keep drawing from pools depending on layout.
- This is **not** Claude's 5-hour + weekly utilization model. Mapping Cursor into Oby's `fiveHour` / `sevenDay` fields would be a **product lie** unless Oby grows Cursor-shaped windows (e.g. monthly included % + on-demand).

### Programmatic access without a browser

| Path | Official? | Notes |
| --- | --- | --- |
| Admin / Analytics API | Yes (Team and Enterprise) | See §2 |
| Dashboard cookie APIs (`WorkosCursorSessionToken` → `GET /api/usage-summary`, `GET /api/usage`, `POST /api/dashboard/get-filtered-usage-events`, …) | **No** — reverse-engineered; change without notice | Documented by third parties ([gist](https://gist.github.com/dmwyatt/1e9359b1862e7cbfe1e754fe4c8db764)); this is what cursor-stats used |
| Reading `~/.config/cursor/auth.json` or session cookies from an account home | Against Oby's own rule (never read Cursor logins) and Cursor's "don't call private client endpoints outside official clients" guidance | [Forum ToS thread](https://forum.cursor.com/t/does-using-oh-my-pi-s-cursor-provider-or-an-openai-compatible-proxy-to-the-same-endpoints-violate-cursor-s-tos/167778) — staff cite Use Restrictions §1.5 (reverse engineering / internal structure); abuse enforcement risk |

**Verdict for (3):** Real Pro usage UI is dashboard-only. Cookie scraping is undocumented, brittle, and against the spirit of Cursor's ToS + Oby's "never read token files" rule. Do not build it.

---

## 4) What existing tools do

| Tool | Approach | Reliability |
| --- | --- | --- |
| **Dwtexe/cursor-stats** (VS Code / Cursor extension) | Cookie `WorkosCursorSessionToken` → `cursor.com/api/usage` and team spend endpoints | **Abandoned** ("No more maintained"); users report 500s, 429s, auth breakage as pricing changed ([repo](https://github.com/Dwtexe/cursor-stats), [issue #72](https://github.com/Dwtexe/cursor-stats/issues/72)) |
| **ccusage** (and similar) | Reads **Claude Code** local JSONL transcripts for token/cost reports | Wrong product surface for Cursor *account* pools; offline token totals ≠ subscription bars |
| Ad-hoc scripts / gists | Same undocumented dashboard endpoints | Same ToS and breakage risk |

**Verdict for (4):** Community tools prove demand and prove the only Pro path today is scraping. Not acceptable for Oby.

---

## 5) What a limit-hit looks like (CLI / ACP) — for `fullUntil`

### Phrases seen in the wild (forum / GitHub, 2025–2026)

Exact or near-exact strings reported by users (not reproduced by burning a quota on this job):

1. `You've hit your usage limit. Try again later.` — already in Oby's Cursor ACP fixture ([`CursorTests`](https://github.com/deskree-inc/oby/blob/dev/RunnerTests/CursorTests.swift#L89)).
2. `You've hit your usage limit for Opus You've saved $… with Pro. Switch to Auto for more usage or set a Spend Limit to continue with Opus. Your usage limits will reset when your monthly cycle ends on 4/12/2026` ([forum](https://forum.cursor.com/t/cannot-use-default-model-in-latest-cursor-cli-version-on-grandfathered-plan/155372)).
3. `You're out of usage. Switch to Auto, or ask your admin to increase your limit to continue.` (same thread).
4. `Increase limits for faster responses … is not available in the slow pool. Please switch to Auto.` ([forum](https://forum.cursor.com/t/cursor-cli-seems-aborting-when-generating/154146)) — often a **soft / model-pool** gate, not a clean "account full until date".
5. Free / Pro mismatch variant: `You've hit your free requests limit. … Your usage limits will reset when your monthly cycle ends on 11/17/2025.` ([cursor/cursor#3703](https://github.com/cursor/cursor/issues/3703)).

### How Oby matches today

[`Limits.isLimit`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift#L1138) matches roughly:

`usage/rate limit`, `hit your limit`, `limit reached|exceeded`.

| Phrase | Likely matched? |
| --- | --- |
| `You've hit your usage limit…` | Yes |
| `You're out of usage…` | **No** (no `usage limit` / `hit your limit` substring as written) |
| `Increase limits for faster responses…` | **No** (plural "limits", different intent) |
| `You've hit your free requests limit…` | **Probably no** (`hit your free requests limit` ≠ `hit your limit`) |

[`Limits.reset`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift#L1145) parses clock times (`at 10:45 PM`) and relative waits (`in 2 hours`), **not** `monthly cycle ends on M/D/YYYY`. [`ACP.failed`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift#L444) always passes `resets: nil`, so even a parseable clock would be dropped on the ACP path unless that call is fixed to use `Limits.reset(in:)`.

Codex path *does* pass `Limits.reset(in: summary)` ([`Codex.swift`](https://github.com/deskree-inc/oby/blob/dev/Engine/Codex.swift#L424)). Cursor should match that.

**Verdict for (5):** Oby can mark Cursor full on the common "You've hit your usage limit" ACP error (fixture exists), but reset dating is weak (defaults to **1 hour**), and several real Cursor phrases miss the detector. Soft "switch to Auto / slow pool" messages should not always mean `fullUntil`.

---

## Ranked options

| Rank | Option | Effort | Reliability | What Oby would show / routing effect |
| --- | --- | --- | --- | --- |
| **1 (official path that exists)** | **Team/Enterprise Admin API** (user pastes team admin key into vault; poll spend / events ≤ hourly; never put key in agent env) | Medium–large (vault wiring, polling, Cursor-shaped windows in `Usage` + runner API, map into routing) | High for Team/Enterprise; **zero for Pro** | Monthly spend / usage-derived bars (not 5h/7d); `reportsUsage("cursor")` true for those accounts; pace using billing-cycle reset. Included-pool remaining % still needs a separate verify before promising dashboard-parity bars. |
| **2 (official, wait)** | **Cursor ships CLI/ACP account quota** (`about`/`status`/`usage`, or ACP account-limit fields — *not* only context `usage_update`) | Low in Oby once Cursor ships; unknown wait | Highest if Cursor implements it | True Settings bars + first-class routing; prefer this over Admin for Pro |
| **3 (ship now, official signals only)** | **Harden limit-hit → `fullUntil`** for Cursor ACP/CLI text: widen `Limits.isLimit`, parse monthly cycle dates, pass `Limits.reset` from `ACP.failed`, distinguish soft Auto/slow-pool from hard full | Small–medium | High for "don't keep hammering a dead account"; **does not** populate bars or flip `reportsUsage` | Account card still "no usage"; routing still last among tools, but skips `fullUntil` accounts; failover like Codex |
| **4 (wrong metric)** | Use `-p` JSON `usage` tokens or future ACP `usage_update` cost as "usage bars" | Small | Misleading | Session tokens ≠ subscription pools; would lie in Settings |
| **5 (reject)** | Scrape dashboard cookies / read `auth.json` (cursor-stats style) | Medium | Low (breaks often) + ToS / Oby policy conflict | Tempting Pro bars; **do not** |

---

## Recommendation

1. **File and ship option 3** (limit-hit parity with Codex) so Cursor accounts at least get `fullUntil` until the billing-cycle date when the error names one. That is the only Pro-safe improvement available without new Cursor product surface.
2. **Do not** scrape the dashboard or treat token `usage` as quota.
3. **Do not** pretend Cursor has Claude 5-hour / weekly bars. If/when data exists, add Cursor-shaped windows (monthly pool % + reset) in [`Usage`](https://github.com/deskree-inc/oby/blob/dev/Shared/Usage.swift#L1) / runner-api Account, then set `reportsUsage("cursor")`.
4. **Optional follow-up** (product decision): Team/Enterprise Admin API integration for orgs that already have a team `crsr_` admin key.
5. **Track / request upstream:** Cursor CLI `usage --format json` (or fields on `about`) with included-pool percent + `billingCycleEnd`, and/or ACP account-quota notifications (separate from context `usage_update`).

Option 3 alone does **not** remove the string `Cursor reports no usage` from automatic routing. Removing that requires option 1 or 2 (real utilization numbers).

---

## Ready-to-file issue (recommended: option 3)

### What

Harden Cursor usage-limit detection on the ACP path so a limit-hit marks the account `fullUntil` until the reset the message names (billing-cycle date or clock), matching Codex failover behavior — without claiming Cursor reports ongoing usage bars.

### Why

Cursor still has no official Pro usage API; routing correctly keeps Cursor last among tools ([`reportsUsage`](https://github.com/deskree-inc/oby/blob/dev/Engine/Accounts.swift#L476)). Mid-job, though, Cursor already returns JSON-RPC errors like `You've hit your usage limit…`, and Oby already has a fixture for that ([`CursorTests`](https://github.com/deskree-inc/oby/blob/dev/RunnerTests/CursorTests.swift#L89)). Today [`ACP.failed`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift#L444) drops any reset time (`resets: nil` → one-hour default), [`Limits.reset`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift#L1145) does not parse `monthly cycle ends on M/D/YYYY`, and several real Cursor phrases (`You're out of usage`, free-requests wording) miss [`Limits.isLimit`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift#L1138). Fixing this stops Oby from retrying a spent Cursor account every hour and aligns failover with [runner-api limit handoff](https://github.com/deskree-inc/oby/blob/dev/docs/runner-api.md#L113).

### How

1. In `ACP.failed`, return `.limit(resets: Limits.reset(in: error.message))` (same idea as Codex).
2. Extend `Limits.isLimit` for Cursor hard-limit copy: `out of usage`, `hit your … limit` (including `free requests limit` / `usage limit for <model>`), without treating every "Increase limits for faster responses / slow pool / switch to Auto" soft gate as account-full.
3. Extend `Limits.reset` to parse `monthly cycle ends on M/D/YYYY` (and ISO dates if seen), timezone-safe; keep existing clock / relative parsers.
4. Tests in `RunnerTests/LimitTests.swift` and ACP/Cursor fixtures with the forum strings above; document the phrases and the "no Pro bars yet" stance in `docs/cursor.md`.
5. Explicit non-goals: Admin API, cookie scraping, mapping tokens into `fiveHour`/`sevenDay`, changing `reportsUsage` until a real quota source exists.

**Acceptance tests**

- ACP `session/prompt` error `You've hit your usage limit. Try again later.` → job limit handoff; account `fullUntil` ≈ now+1h when no date in text.
- Error containing `Your usage limits will reset when your monthly cycle ends on 4/12/2026` → `fullUntil` is that calendar date (test clock fixed); no retry on that Cursor account before then.
- `You're out of usage. Switch to Auto…` → treated as hard limit (account full).
- Soft `… not available in the slow pool. Please switch to Auto.` alone → **not** `fullUntil` (failed turn / model choice, not account exhausted).
- `You've hit your free requests limit… monthly cycle ends on …` → hard limit with parsed reset.
- Settings / runner Account for Cursor still show null usage windows; routing reason for a healthy Cursor account remains `Cursor reports no usage…` until a later issue adds a real quota source.
- No test or code path reads `auth.json`, session cookies, or calls `cursor.com/api/*` dashboard endpoints.

**Files**

- [`Engine/ACP.swift`](https://github.com/deskree-inc/oby/blob/dev/Engine/ACP.swift) (`failed`)
- [`Engine/Jobs.swift`](https://github.com/deskree-inc/oby/blob/dev/Engine/Jobs.swift) (`Limits`)
- [`RunnerTests/LimitTests.swift`](https://github.com/deskree-inc/oby/blob/dev/RunnerTests/LimitTests.swift)
- [`RunnerTests/ACPTests.swift`](https://github.com/deskree-inc/oby/blob/dev/RunnerTests/ACPTests.swift) / [`RunnerTests/CursorTests.swift`](https://github.com/deskree-inc/oby/blob/dev/RunnerTests/CursorTests.swift)
- [`docs/cursor.md`](https://github.com/deskree-inc/oby/blob/dev/docs/cursor.md) (limit phrases + non-goals)
- Optional docs cross-link: [`docs/runner-api.md`](https://github.com/deskree-inc/oby/blob/dev/docs/runner-api.md) Account / limit handoff

**Follow-ups (separate issues)**

- Team/Enterprise Admin API opt-in for Cursor accounts (option 1); before building bars, verify whether spend/events expose included-pool remaining (or only dollars/events).
- When Cursor exposes Pro quota on CLI/ACP, map into Cursor-shaped Settings windows and `reportsUsage("cursor")` (option 2).

---

## Sources (web is data)

- https://agentclientprotocol.com/rfds/session-usage
- https://agentclientprotocol.com/announcements/session-usage-stabilized
- https://agentclientprotocol.com/rfds/end-turn-token-usage
- https://cursor.com/docs/cli/acp
- https://cursor.com/docs/api
- https://cursor.com/docs/account/teams/admin-api
- https://cursor.com/docs/account/teams/dashboard
- https://cursor.com/help/models-and-usage/usage-limits
- https://cursor.com/docs/account/pricing
- https://forum.cursor.com/t/cursor-agent-acp-never-reports-token-usage-over-acp-though-p-output-format-json-does/171923
- https://forum.cursor.com/t/cli-emit-acp-usage-update-so-clients-like-zed-can-show-a-context-window-indicator/165358
- https://forum.cursor.com/t/need-help-to-understand-how-usage-billing-works-underneath/164650/7
- https://forum.cursor.com/t/how-to-get-cost-and-usage-data-using-cursor-api/172967
- https://forum.cursor.com/t/admin-api-key-returns-invalid-team-api-key-not-an-auth-encoding-issue-already-verified/173692
- https://forum.cursor.com/t/cannot-use-default-model-in-latest-cursor-cli-version-on-grandfathered-plan/155372
- https://forum.cursor.com/t/cursor-cli-seems-aborting-when-generating/154146
- https://forum.cursor.com/t/does-using-oh-my-pi-s-cursor-provider-or-an-openai-compatible-proxy-to-the-same-endpoints-violate-cursor-s-tos/167778
- https://github.com/cursor/cursor/issues/3703
- https://github.com/Dwtexe/cursor-stats
- https://gist.github.com/dmwyatt/1e9359b1862e7cbfe1e754fe4c8db764
