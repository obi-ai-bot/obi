# Plug-ins

Each folder here is one optional plug-in. Its folder name is its id, and it holds an `obi-plugin.json` manifest (docs/ARCHITECTURE.md, section 5). Plug-ins add context, events, or an MCP server for agents. Oby works fully with none of them.

- **Installed** into `obid`'s `home/plugins/<id>/`. `obid` reads that folder at start and lists every plug-in it finds (`GET /v1/obid/plugins`).
- **Disabled** until the owner enables one with `PUT /v1/obid/plugins/{id}` and `{"enabled": true}`. No manifest field can enable a plug-in by itself.
- **Sandboxed** when it has a process (`run`): bubblewrap on Linux, Seatbelt on macOS. The process can write only to `home/plugin-data/<id>/`, can read only its own folder of `obid`'s home, and gets only `PATH`, `HOME`, `LANG` and `TMPDIR` in its environment. It has the network, but not the machine's local services, because one of them could start a process outside the sandbox for it, or read or write the person's things for it:
  - on macOS: no LaunchServices (`open`), no Apple Events, no Mach services but those for users, logging, name lookups and TLS trust; no preferences (`cfprefsd` and preference reads and writes are denied, and `/Users` is hidden, so the person's `~/Library/Preferences` can't be read either), no pasteboard, no keychain (`securityd`, `secd`, SecurityAgent); no Unix socket outside its data folder; no signal to a process outside its sandbox; `/tmp`, `/var/tmp` and `/var/folders` (every user's `TMPDIR`) can't be read;
  - on Linux: `/tmp`, `/var/tmp` and `/run` are empty and read-only (the resolver's folder under `/run` is bound back in).

  Use `TMPDIR` for temporary files.
- **Restarted** when it fails (it exits, or doesn't answer `initialize` or a `ping` in time): after 1 second the first time in a row, after 2 seconds the second; its third failure in a row makes it `failed`, and it stays stopped until the owner enables it again.
- **Stopped with everything it started.** When it is disabled, when `obid` stops and each time it fails, no process it started is left running, also none that called `setsid`: on Linux its sandbox's PID namespace ends with it; on macOS the sandbox's first process, a watcher, kills every process in the sandbox.

What the macOS sandbox can't stop:

- A process can read the arguments and environment of the user's other processes (not Apple's own), `obid`'s included, so no secret belongs in an environment there.
- The plug-in's processes can signal the watcher, since it is in their sandbox: a plug-in that kills its watcher before it stops can leave processes it started outside its process group running. `obid` then ends the process group and logs that the watcher was killed.

On Linux, Unix sockets in the abstract namespace (no file) stay reachable, because the plug-in shares the machine's network namespace.

**Event plug-ins** declare the kinds they emit in the manifest's `events.kinds`, and send each event with `events/emit` (docs/ARCHITECTURE.md 5.4). An `obi-plugin/0.1` manifest may list the five GitHub kinds (`pull_request.review_requested`, `pull_request.changes_requested`, `issue.assigned`, `check.failed`, `mention`). Work from anywhere else needs `"manifest": "obi-plugin/0.2"` and its kinds: `deploy.failed` (with `subject.project` and `subject.environment`), `alert.fired` (`subject.project` and `subject.severity`) and `ticket.assigned` (`subject.ticket`), and `data.text` for a log's tail or a message, at most 16 KiB. On one of `obid`'s repositories (`subject.repo`) they become offers the owner starts with one tap; whatever the plug-in wrote reaches the agent only quoted. `core/crates/obid/tests/plugins/alerts` is a working example in `sh`.

| Plug-in | Kind | |
|---|---|---|
| [`tetrix`](tetrix/) | `agent-mcp` | Tetrix's code graph and memory, for a job's agents. |

The host that finds, starts and talks to plug-ins is `core/crates/obi-plugin-host`. Its tests run a test plug-in of each kind (`core/crates/obi-plugin-host/tests/plugins/`).
