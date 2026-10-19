# Fast replies: from Send to Oby's first words

The owner's ask (2026-10-19): Oby's conversation should answer as fast as Claude Code and the ChatGPT and Codex desktop apps. This page has what the fastest harnesses do, where Oby's seconds went, what changed, and what's left.

## What the fast harnesses do

- **One agent process stays running.** Anthropic recommends Claude Code's streaming input mode, where the agent runs "as a long lived process that takes in user input" and each message goes to the same process ([Agent SDK: streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)). The SDK can even start it before the first prompt (`startup()`, `prewarm()`; [TypeScript SDK](https://code.claude.com/docs/en/agent-sdk/typescript)). Codex's IDE extension runs on `codex app-server`, one process for every thread ([source](https://github.com/openai/codex/tree/main/codex-rs/app-server)). OpenCode's UI talks to a local server: `prompt_async` answers 204 at once and the words come over SSE ([OpenCode server](https://opencode.ai/docs/server/)).
- **They warm what comes next.** When a Codex thread starts or wakes, a background task opens the model's WebSocket and sends a warm-up request, so the first real turn starts sooner ([`startup_prewarm.rs`](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/startup_prewarm.rs)). Aider can ping every 5 minutes to keep the prompt cache warm ([`--cache-keepalive-pings`](https://aider.chat/docs/config/options.html)).
- **Words stream as tokens.** Without partial messages, Claude Code gives a text block only once it's finished. `--include-partial-messages` gives each `text_delta` as it comes, and a tool call's start ([streaming output](https://code.claude.com/docs/en/agent-sdk/streaming-output)). Cline renders each partial block as it arrives and merges renders behind a lock, so the UI never falls behind ([Cline overview](https://github.com/cline/cline/blob/main/.clinerules/cline-overview.md)).
- **The prompt prefix stays the same, so the cache holds it.** The order is the system prompt and tools, then CLAUDE.md, then the conversation. Switching model, connecting an MCP server, or upgrading Claude Code rebuilds the whole prefix. On a Claude subscription the main conversation's cache lasts 1 hour; with an API key it's 5 minutes unless `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` ([how Claude Code uses prompt caching](https://code.claude.com/docs/en/prompt-caching); [why caching matters](https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything)). Anthropic measured a 10-turn chat with a long system prompt going from about 10 s to 2.5 s to the first token with the cache ([prompt caching](https://claude.com/blog/prompt-caching)).
- **No model call before the answer starts.** None of these harnesses runs a router or planner ahead of the reply.

## Where Oby's seconds went (measured 2026-10-19)

Oby already streamed partial messages, and a conversation never waited for the brain: the harness turn starts at once. The time went before the agent and around it:

- **Repositories were extracted on the critical path.** Every new conversation, and every turn after `dev` moved, extracted each repository (`git archive | tar`, 22 MB and 1,678 files for obi) before "Thinking" showed. That took 3.2–3.5 s just now, and more under heavier load. The owner's own turns on 2026-10-18 and 19 waited 2.4 to 40.5 s between the POST and Claude Code receiving the prompt (from `conversations/<id>.json` against the session transcripts). New conversations were the slow ones: 6.7, 13.8, 13.9 and 40.5 s.
- **A new `claude` started for every turn.** Starting it, connecting Oby's MCP server (`init` waits until every MCP server is connected: a test server that took 4 s per request pushed `init` from 3.6 s to 18.4 s), and reading its session again with `--resume` took 2–7 s per turn. On the same machine, a running `claude` answered its next prompt with its first word in 0.76–0.83 s; a fresh one took 4.25 s.
- **Waiting for the process to exit.** After its `result`, obid waited up to 3 s for Claude Code to exit before sending the reply and answering the POST.

## What changed (this pull request)

1. **A conversation's Claude Code waits for its next turn** (`brain/harness.rs`, `Warm`). After a turn that answered, the process keeps running in the same box with the same login copy and MCP token, and the next turn is written to its stdin. The token is good only while a turn is under way, the scrub runs before every turn, and the login copy stays fresh through the keeper and is taken out when the process ends. It waits 30 minutes at most, and at most 3 conversations' wait at once. It ends on a stop, a cancel, the budget, a deleted conversation, obid's stop, or a login copy near its end. When one has died, the next turn resumes the session as before.
2. **Rooms never wait for a checkout obid could keep ready.** obid keeps a spare tree of each repository at its default branch (`home/checkouts/<repo>/spare-<sha>`). A new room takes it with a rename, and the next spare is made in the background. A room whose branch moved keeps its tree for the turn, while the new tree is extracted beside it and swapped in with renames.
3. **A stopwatch line for every turn** in obid's log: `turn … ended in its session: answered (its turn 0 ms, repositories 60 ms, its Claude Code was running 97 ms, starting 97 ms, session 109 ms, first words 834 ms, ended 1331 ms)`.

## Before and after

Measured with a throwaway obid (debug build, its own home, events followed over `GET /v1/events`), on the "Personal" Claude account (Sonnet 5.5), with field/fixture-app and obi-ai-bot/obi as repositories. It ran 4 tiny prompts in one new conversation, then 1 in a second new conversation. The Mac's load average was 250–350 throughout. "First words" is POST to the first `delta` event; "answer" is POST to the POST's answer.

| Turn | First words before | after | Answer before | after |
|---|---|---|---|---|
| A follow-up in a conversation | 5.6–6.3 s | **1.1–1.5 s** | 7.0–7.3 s | **1.6–1.9 s** |
| A second new conversation | 8.6 s (3.2 s of it extracting obi) | 2.9–9.4 s (repositories 53–134 ms; starting Claude Code 1.3–7.2 s, depending on load) | 10.0 s | 3.4–10.1 s |
| The first conversation after obid's start, no clone yet | 16.0 s | 6.2–20.4 s (cloning obi both times) | 17.4 s | 6.2–20.4 s |

"After" covers two runs of the same script: one with the warm process and spare trees, and one with the final code. A new conversation now waits only for Claude Code to start. The extraction is gone, but at load 300 the start itself took 1.3 to 7.2 s.

## A new conversation's Claude Code, started ahead

Claude Code connects its MCP servers when it starts, before any prompt: with a test server that took 4 s per request and a prompt sent 25 s after the start, `init` came 41 ms after the prompt. So a Claude Code started ahead saves both its start and the connection, as the Agent SDK's `prewarm()` does.

After each of the owner's turns, obid names the next new conversation's id and readies its room, box, login copy and MCP configuration, then starts its Claude Code with no prompt. Until a turn is under way, its token may only connect to Oby's tools and list them. The new conversation's first turn is written to it like a follow-up.

Measured the same way, back to back with #726's code, at load 290–350. The second new conversation in a run got:

| | #726 | Started ahead |
|---|---|---|
| POST until Claude Code had the prompt (`session` in the stopwatch line) | 1.8–2.8 s | **0.14–0.29 s** |
| First words | 3.2–10.0 s | **0.85–4.8 s** (the model's own latency was noisy in this window: follow-ups took 0.8–4.9 s too) |

## What's left

- **Codex conversations** still start `codex app-server` every turn. One app-server for all of a conversation's turns, or all conversations' threads, would do for Codex what the change above does for Claude Code.
- Show the model's thinking (`thinking_delta`) and a tool's start (`content_block_start`) as they stream, instead of waiting for the whole tool-use block.
