# Oby's runner

The runner is Oby's engine without the notch, as a Linux service: the brain, Oby's own clones and job worktrees, Claude Code and Codex, accounts and Publish. It runs on an always-on machine (first: `tetrix-lab`), so the iPhone app can plan, dispatch and follow jobs while the Mac is closed. Its API is [`docs/runner-api.md`](../docs/runner-api.md).

It shares `Engine/` with the Mac app. `Package.swift` at the root of the repository builds both the engine and the runner.

## Build

You need Swift 6.4 ([swiftly](https://www.swift.org/install/linux/)), SQLite's headers and bubblewrap:

```sh
sudo apt install libsqlite3-dev bubblewrap
swift build -c release
swift test
```

Agents (and the checks Oby runs between rounds) run inside `bwrap`, because they run as the runner's own user. Their home is empty except for the folders the tools live in (`Agents.tools`: `~/.local/bin`, `~/.local/lib`, `~/.local/share/claude`, `~/.local/share/swiftly`, `~/.npm`, `~/.swiftpm`, each a throwaway copy), git's settings (read-only) and their own account's home. All of `OBY_HOME` is empty too. Everything else is read-only, except their worktree and the git data it commits to. If a runner's tools live somewhere else in home (`~/.nvm`, `~/.cargo`), add that folder to `Agents.tools`. Without `bwrap`, agents don't start. Use Ubuntu's package: its AppArmor profile lets it make the namespaces it needs.

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
| `OBY_HOME` | Where the runner keeps everything: `oby.sqlite` (jobs, and the brain's latest 200 turns), `accounts.json`, `devices.json` (the phones that may approve publishing; to add one, `touch $OBY_HOME/pairing` and open the app within 10 minutes), `cleared.json` (when Clear done was last pressed, on any app), `apns/` (the APNs key and the phones' Live Activity tokens), `vault/` (the secrets Oby uses but never shows), `watch.json` and `watches.json` (the Watch API's Cloudflare Access settings and the paired Apple Watches), `repos/` and `jobs/`. The service uses `/srv/nvme/oby`. |
| `OBY_PORT` | The port on `127.0.0.1`. 7777 by default. |
| `OBY_WATCH_PORT` | The Watch API's port on `127.0.0.1`, for the Cloudflare Tunnel. 7778 by default. |

The models and efforts the app picks in Settings › Models are kept in `~/.config/oby-runner.plist`.

## Speech

Speech runs directly on the runner's CPU with whisper.cpp. As the runner's owner on tetrix-lab, run `OBY_HOME=/srv/nvme/oby Runner/scripts/setup-whisper.sh` to build the CLI and download the multilingual fast and final models. The script needs `git cmake build-essential curl util-linux`, can be run again safely, and stores everything under `OBY_HOME/whisper`.

`POST /v1/speech` accepts short PCM/WAV chunks and returns partial or final text. It never sends audio to an agent or logs it. The prompt uses product names and the runner's current repository names by default. Model paths, CPU threads and a prompt override are environment settings; the full contract and defaults are in [the runner API](../docs/runner-api.md#post-v1speechdeviceuuidutteranceuuidfinalfalselanguageauto).

## Vault

Secrets for connections you make (an API token for a service) live in `vault/secrets.json` in `OBY_HOME`: the folder is 0700 and the file 0600, owned by the runner's user. Agents never see it: all of `OBY_HOME` is empty in their bubblewrap.

- **Nothing outgoing holds one.** The secret scan learns every value, plain, base64, hex and URL-encoded. A publish is blocked when one is in a file of any commit it pushes (each file read whole, merges too), a hunk, a file's name, a commit message, the branch's name, or the pull request; so are review comments and the comment that claims an issue.
- **No agent gets one.** The brain, the Lead and every job's agent get prompts, messages, quoted issues and pull requests, attachments, the Lead's context files and reviews with the values taken out, and no variable of the runner's environment that holds one. A binary attachment that holds one stops the job.
- **Nothing shown or logged holds one.** Log lines (the runner's journal and the Mac's OSLog), the API's answers and events, and the pushes to the phone have them taken out.
- **Fail closed.** If the file or its folder is readable by anyone else, or owned by someone else, the runner doesn't read it: until it's fixed nothing is published, no agent starts or is told anything (the job says why), and no push, API answer or event goes to the apps.

Run these as the runner's user, with its `OBY_HOME`. The value comes on stdin (typed without echo, or piped), never as an argument, and nothing prints it:

```sh
OBY_HOME=/srv/nvme/oby oby-runner vault add staging-api-key
OBY_HOME=/srv/nvme/oby oby-runner vault list
OBY_HOME=/srv/nvme/oby oby-runner vault remove staging-api-key
```

The running service sees the change at its next scan.

## Live Activity push

With an APNs key, the runner keeps the iPhone's Live Activity current while the app is suspended, and starts it when a job begins with the app closed ([`POST /v1/activities`](../docs/runner-api.md)). Without one it runs as before, and the app catches up when it opens.

1. In the Apple Developer account of the iPhone app's team, make a key with Apple Push Notifications service (APNs) on. Download `AuthKey_<KEY ID>.p8`: Apple lets you download it once.
2. Put it in `apns/` in `OBY_HOME`, readable only by the runner's user, with `apns.json` beside it:

   ```sh
   install -d -m 700 /srv/nvme/oby/apns
   install -m 600 AuthKey_ABC123DEFG.p8 /srv/nvme/oby/apns/
   echo '{"team": "PQKAL8E36D", "key": "ABC123DEFG"}' > /srv/nvme/oby/apns/apns.json
   systemctl --user restart oby-runner
   ```

   `team` is the Team ID, `key` the Key ID. The log says `Live Activity push is on` (or why it's off). The key never leaves that folder; don't commit or copy it anywhere else.
3. The app hands over its tokens when it opens. Pushes go out with `curl --http2` (the runner needs curl with HTTP/2, as Ubuntu's has), to Apple's development service for builds from Xcode and its production one for TestFlight.

## Put it on the tailnet

The runner listens on `127.0.0.1` only. `tailscale serve` publishes it on the tailnet with a real HTTPS certificate, and tells the runner who is asking:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:7777
```

On `tetrix-lab`, port 443 belongs to the Tetrix stack, so the runner is on 8443: the iPhone app's base URL is `https://tetrix-lab.tail8de49b.ts.net:8443`. Nothing on the tailnet API is reachable from the internet.

## The Apple Watch without its iPhone

watchOS can't run Tailscale, so the Watch reaches a second, smaller API (`docs/runner-api.md`, "The Watch API") through a Cloudflare Tunnel, behind Cloudflare Access. The runner always listens for it on `127.0.0.1:7778`, and lets nothing through until `watch.json` is set up.

1. In Cloudflare Zero Trust, make a service token (Access › Service auth) and a self-hosted Access application for a hostname of yours, say `oby-watch.example.com`, with one policy: **Service Auth**, that token. Note the application's AUD tag.
2. Run the tunnel on the runner's machine, pointing that hostname at the Watch API: `cloudflared tunnel create oby-watch`, then in its config `ingress: [{hostname: oby-watch.example.com, service: http://127.0.0.1:7778}, {service: http_status:404}]`, and `cloudflared service install`.
3. Write `$OBY_HOME/watch.json` (mode 600), with the team's keys from `curl https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`:

   ```json
   {"url": "https://oby-watch.example.com", "team": "<team>", "audience": "<AUD tag>", "keys": [<the "keys" list>]}
   ```

   Cloudflare rotates those keys every six weeks: paste the new list in (the runner reads the file again when it changes; the journal says when it can't use it).
4. On the iPhone, Settings › Apple Watch without iPhone: paste the service token's client ID and secret, open Oby on the watch, and tap **Pair Apple Watch** (Face ID). The runner keeps the token in its vault (`watch-access-client-id`, `watch-access-client-token`), so no agent sees it and nothing outgoing carries it; swipe a watch there to remove it.

## Logs

```sh
journalctl --user -u oby-runner -f
```

The log lists the registered phones at startup, and every turn of the brain: the words the user typed, the plan it made (or the rules' plan when it didn't answer), and any plan Swift refused, with why. Stopping the service ends running agents, and their jobs show as interrupted.

## Run it by hand

```sh
OBY_HOME=$(mktemp -d) OBY_OWNER=test OBY_PORT=7790 .build/release/oby-runner
curl -s -H 'Tailscale-User-Login: test' localhost:7790/v1/status
```
