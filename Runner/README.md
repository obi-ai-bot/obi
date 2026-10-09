# Oby's runner

The runner is Oby's engine without the notch, as a Linux service: the brain, Oby's own clones and job worktrees, Claude Code and Codex, accounts and Publish. It runs on an always-on machine (first: `tetrix-lab`), so the iPhone app can plan, dispatch and follow jobs while the Mac is closed. Its API is [`docs/runner-api.md`](../docs/runner-api.md).

It shares `Engine/` with the Mac app. `Package.swift` at the root of the repository builds both the engine and the runner.

## Build

You need Swift 6.4 ([swiftly](https://www.swift.org/install/linux/)) and SQLite's headers:

```sh
sudo apt install libsqlite3-dev
swift build -c release
swift test
```

## Sign in on the runner

The runner works as the user it runs as, with that user's own logins, like Oby does on the Mac. Sign in once, in a terminal on the machine:

- `gh auth login`: the repositories Oby may work on, and Publish.
- `claude auth login`, and `codex login` if you use Codex.

Oby never reads these logins. More accounts go in `accounts.json` in `OBY_HOME`, each with its own home (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`); sign in to each with that variable set.

## Install

```sh
install -D .build/release/oby-runner ~/.local/bin/oby-runner
mkdir -p ~/.config/systemd/user
sed "s/OWNER_LOGIN/you@example.com/" Runner/oby-runner.service > ~/.config/systemd/user/oby-runner.service
systemctl --user daemon-reload
systemctl --user enable --now oby-runner
loginctl enable-linger "$USER"   # keeps it running while nobody is logged in
```

Put the owner's Tailscale login in place of `you@example.com` (`tailscale status --json | jq -r '.User[] .LoginName'` lists them). The runner answers only that login, and won't start without one.

| Variable | What it is |
| --- | --- |
| `OBY_OWNER` | The owner's Tailscale login. Required. |
| `OBY_HOME` | Where the runner keeps everything: `oby.sqlite` (jobs), `accounts.json`, `devices.json` (the phones that may approve publishing), `repos/` and `jobs/`. The service uses `/srv/nvme/oby`. |
| `OBY_PORT` | The port on `127.0.0.1`. 7777 by default. |

The models and efforts the app picks in Settings › Models are kept in `~/.config/oby-runner.plist`.

## Put it on the tailnet

The runner listens on `127.0.0.1` only. `tailscale serve` publishes it on the tailnet with a real HTTPS certificate, and tells the runner who is asking:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:7777
```

On `tetrix-lab`, port 443 belongs to the Tetrix stack, so the runner is on 8443: the iPhone app's base URL is `https://tetrix-lab.tail8de49b.ts.net:8443`. Nothing is reachable from the internet.

## Logs

```sh
journalctl --user -u oby-runner -f
```

The log lists the registered phones at startup. Stopping the service ends running agents, and their jobs show as interrupted.

## Run it by hand

```sh
OBY_HOME=$(mktemp -d) OBY_OWNER=test OBY_PORT=7790 .build/release/oby-runner
curl -s -H 'Tailscale-User-Login: test' localhost:7790/v1/status
```
