# Talking to Oby: the conversation harness

The owner's decision (2026-10-17): talking to Oby works like talking to Claude Code, ChatGPT or Codex. A conversation is a real agent session with the agent's own harness (reading and searching code, the web, running things, sub-agents) plus Oby's own tools, and what it makes to be looked at is an artifact the apps show. Sangam's design stays as it is: this is the logic under it. Whichever agent runs the conversation (Claude Code first, then Codex, then anything over ACP), it gets the same Oby tools, so it works the same.

What it replaces: obid's plan loop (`brain/`), where each step is a fresh model call that proposes one typed action. That loop stays as the fallback when no agent account can run, and as the event orchestrator's (#590).

## 1. Talking and work stay apart

As in Sangam's design (design/app `chats.ts`, `tasks.ts`):

- **A conversation is talking.** Home's message box starts one; a reply carries it on. Oby works in the open (its steps and tool calls show as it goes), its words stream in, and most turns end in an answer. It is never a task.
- **A task is work.** It exists only once Oby starts one (a job, with its card under Oby's words and its row on Home), runs in its own worktree, and has its own thread with its agent. Telling a finished task something picks it up again at once (#644).

## 2. A conversation is an agent session

- **One session per conversation.** obid starts the conversation's agent on its first turn and resumes the same session on every later turn (`claude -p --resume <session>` with stream-json in and out, as jobs run Claude Code; Codex: `thread/start`, then `turn/start` on the same thread). A conversation remembers what was said because the agent's session does; obid also keeps every turn (`GET /v1/conversation`), as today.
- **Its room.** `home/conversations/<id>/room/`, the agent's working folder and `HOME`-like temp, in the same sandbox as a job (bubblewrap on Linux, Seatbelt on macOS) with:
  - writes: only its room;
  - reads: its room, and a read-only checkout of each configured repository at its default branch (`home/conversations/<id>/room/repos/<owner>/<name>`, made from obid's clones; refreshed at the start of a turn when the default branch moved);
  - network: the model's API and the web (web search and fetch are part of talking), as a job's in Ask mode asks before;
  - no code-host login, no vault secret, no other conversation's room, no job's worktree.
- **Its tools.** The agent's own: read, search, list, web search, web fetch, run a command (in the room), write a file (in the room), sub-agents, a to-do list. Permission prompts are answered by obid's policy in Sandbox mode: inside the room, yes; the network for the web, yes; secrets and anything outside the room, no (a conversation never asks the owner mid-sentence: what it can't do, it says).
- **Oby's tools** (section 3), from obid's MCP endpoint for the conversation, `POST /v1/agent/mcp/conversation-<id>` with a token of the session's own, like a job's connected-app broker.
- **The model.** The account's Claude Code default (Sonnet for talking unless the owner picks another in Settings › Models › Conversations); Opus when the owner asks for it in words for that conversation.
- **When it can't run** (no agent account signed in, the agent fails twice), the turn falls back to the plan loop and says so in one line.

## 3. Oby's tools (MCP server `oby`)

The same for every agent. obid checks every call against the same rules the plan loop's actions follow today (`brain/actions.rs`), and anything that persists, widens trust or starts work in Bypass is a `confirm` item only the owner's answer runs.

| Tool | Input | Does |
|---|---|---|
| `oby_jobs` | `{status?, repo?, limit?}` | Lists jobs, newest first: id, title, status, step, repo, agent, account, PR. |
| `oby_job` | `{id}` | One job: its request, summary, report, pipeline, PR, files changed, what it's waiting for. Agent-written text is returned as quoted data. |
| `oby_dispatch` | `{repo, task, kind?, agent?, account?, mode?, issue?, title?}` | Starts a job from this conversation (`conversation` set on the job, its card on the turn). Same validation as the plan loop's dispatch. |
| `oby_tell_job` | `{id, words}` | The owner's words to a job (#542), the agent's quoted after them: running, at its next turn; ended, a follow-up with the same kind, agent, account, repository and conversation, the owner's words its request and what the first job did quoted in its first prompt, its card on the turn (Sangam's design, the owner's decision of 2026-10-18, which replaced #644's one more round). After the turn read something untrusted, the follow-up is a `start` item for the owner's Start. A follow-up counts against the turn's ten jobs, at most one per job a turn. |
| `oby_stop_job` | `{id}` | Stops a running job. |
| `oby_inbox` | `{}` | What waits for the owner, what needs them first, each item with its `triage`. |
| `oby_answer` | `{item, answer}` | Answers an inbox item the plan loop may answer; the owner's own decisions (permissions, confirms, publishing) are refused with why. |
| `oby_conversations` | `{query}` | Finds past conversations by what was said (#593). |
| `oby_artifact` | `{title, path, kind?, artifact?}` | Publishes a file or folder from the room as an artifact, or a new version of `artifact` (section 4). |
| `oby_read` | `{path, offset?, limit?}` | A text file of the room (`repos/` included), its lines numbered: at most 2,000 lines and 256 KB at a time. Quoted data. |
| `oby_search` | `{pattern, path?, glob?}` | A regex search of the room's text files under `path`: at most 200 matches. Quoted data. |
| `oby_list` | `{path?, glob?}` | A folder's entries, or with `glob` every file under it that matches: at most 500. |

The read tools are how any agent reads (Codex has no shell, so no other way): only inside the room once links are followed, never `..` or its `config/` (Codex's login copy), `login/`, `home/` or `session.json`, the same refusals and taint as Claude Code's Read, Grep and LS (`repos/` and `attachments/` taint), files opened with `O_NOFOLLOW` and checked again once open, a search held to 32 MB and 10 seconds and ended with its turn, answers and refusals fenced, and every known secret taken out.

## 4. Artifacts

What an agent makes to be looked at: a page, a doc, a chart, a canvas of design options, a PDF, an image.

- **Made** by `oby_artifact` from the conversation's room, or by a job (its `.obi/artifacts/` folder, published when the job ends). Kinds: `html` (a folder with an `index.html`), `markdown`, `image`, `pdf`, `canvas` (an artboard: a JSON list of frames, each an HTML page with a size and position).
- **Kept** in `home/artifacts/<id>/<version>/`, every version, with `artifact.json` (`id`, `title`, `kind`, `conversation`, `job`, `created`, `versions`).
- **API**: `GET /v1/artifacts?conversation=&job=`, `GET /v1/artifacts/{id}`, `GET /v1/artifacts/{id}/{version}/{path}` (the files), `PATCH /v1/artifacts/{id}` (`title`), `DELETE /v1/artifacts/{id}`; an `artifact` event when one is made or gets a version; the turn that made it carries `artifacts: [{id, version}]`. On the gateway's allowlist (the phone shows them).
- **Shown** as a card under the words that made it, opening in a viewer in Sangam's style: HTML in a web view with scripts on, Markdown rendered, images and PDFs native, a canvas as a pannable artboard of its frames. obid sends `Content-Security-Policy: default-src 'self' data: blob:; …; connect-src 'none'; …; sandbox allow-scripts` on every file it serves from an artifact (docs/runner-api.md, "obid only: artifacts"), which stops the page loading or fetching anything but its own files. It doesn't stop the page navigating itself away, a meta refresh, WebRTC or DNS prefetch: that is the client's part.
- **The client contract** for showing an artifact page (every app, the web one too):
  - Render it through a scheme handler (or a local proxy) that fetches each file from obid with the token and passes obid's `Content-Security-Policy` header on unchanged, or in a frame with `sandbox="allow-scripts"`. Never `allow-same-origin`, never with obid's API origin.
  - Never load its HTML with `blob:` URLs, `srcdoc` or `loadHTMLString` outside such a sandbox: those drop obid's header.
  - Deny every navigation in the web view's delegate (`WKNavigationDelegate` on Apple, `WebViewClient` on Android): only the artifact's own files load; a link the user taps may open outside the viewer, in the browser, after they confirm.
  - Load it with network access denied where the platform can (WebRTC off, no DNS prefetch).
- Sharing outside Oby (#387) comes after.

## 5. Events

Besides `step`, `thinking`, `reply` and `turn` (unchanged):

- `delta`: `{conversation, turn, text}`, the agent's words as they're written. Apps append them; the turn's final text replaces them.
- `step` gains `tool` (`read`, `search`, `web_search`, `web_fetch`, `bash`, `write`, `agent`, `oby_*`) and `detail` (the file, query, URL or command, secrets taken out), so the apps show what Oby is doing like Claude Code's tool lines.
- `artifact`: `{id, version, title, kind, conversation, job}`.

## 6. Guardrails (Claude Code's, kept)

- The agent never publishes, pushes, merges or holds a code-host login; Oby's publish gate is the only way out, as for jobs.
- What it reads from the web or a repository is data. It can't act past Oby's tools, and those keep obid's rules (section 3).
- No vault secret, token or agent login ever reaches the room, a tool result, an event or an artifact; obid's redaction runs on everything it passes on.
- Every turn has a budget (time and the model's turns); Stop ends it and says what was done.
- **Known gap: the web is a way out.** A conversation runs no code, and work it plans after reading anything untrusted waits for the owner, but WebFetch itself still goes anywhere: after a prompt injection (from a page, a repository's code, a job's report or an attachment) the agent could put what it read in the room or the repositories' checkouts into a URL it fetches. Secrets obid knows are redacted from what reaches the agent and from its words, but the code and text it reads are not. The next step is a domain allowlist for WebFetch (and WebSearch's results), set by the owner, with everything else refused.

## 7. Order of work

1. **Core**: the conversation session (Claude Code), its room and sandbox, `delta` and tool `step` events, Oby's tools for conversations, the fallback. API in docs/runner-api.md, "obid only: the conversation harness".
2. **Artifacts**: the store, the API and the `artifact` event, `oby_artifact`, jobs' `.obi/artifacts/`, CSP.
3. **Apps**: streamed words, tool lines, artifact cards and the viewer, on the iPhone and the Mac (web after).
4. **Codex** (and Cursor over ACP) as the conversation's agent, with the same Oby tools.
