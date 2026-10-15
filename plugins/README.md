# Plug-ins

Each folder here is one optional plug-in. Its folder name is its id, and it holds an `obi-plugin.json` manifest (docs/ARCHITECTURE.md, section 5). Plug-ins add context, events, or an MCP server for agents. Obi works fully with none of them.

- **Installed** into `obid`'s `home/plugins/<id>/`. `obid` reads that folder at start and lists every plug-in it finds (`GET /v1/obid/plugins`).
- **Disabled** until the owner enables one with `PUT /v1/obid/plugins/{id}` and `{"enabled": true}`. No manifest field can enable a plug-in by itself.
- **Sandboxed** when it has a process (`run`): bubblewrap on Linux, Seatbelt on macOS. The process can write only to `home/plugin-data/<id>/`, can read only its own folder of `obid`'s home, and gets only `PATH`, `HOME`, `LANG` and `TMPDIR` in its environment. It has the network, but not the machine's local services, because one of them could start a process outside the sandbox for it: on macOS no LaunchServices (`open`), no Apple Events, no Mach services but those for users, logging, name lookups, TLS trust and preferences, no Unix socket outside its data folder, no signal to a process outside its sandbox; on Linux `/tmp`, `/var/tmp` and `/run` are empty and read-only (the resolver's folder under `/run` is bound back in); on macOS `/tmp`, `/var/tmp` and `/var/folders` (every user's `TMPDIR`) can't be read. Use `TMPDIR` for temporary files. One thing the macOS sandbox can't stop: a process can read the arguments and environment of the user's other processes (not Apple's own), `obid`'s included, so no secret belongs in an environment there.

| Plug-in | Kind | |
|---|---|---|
| [`tetrix`](tetrix/) | `agent-mcp` | Tetrix's code graph and memory, for a job's agents. |

The host that finds, starts and talks to plug-ins is `core/crates/obi-plugin-host`. Its tests run a test plug-in of each kind (`core/crates/obi-plugin-host/tests/plugins/`).
