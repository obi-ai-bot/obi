# Installing obid (#585)

`obid` is Oby's server: it plans, runs jobs and keeps their results, and the apps talk to it over the runner API ([runner-api.md](runner-api.md)). This page is how to put it on a machine as a service that starts by itself: on a Mac as a launchd agent, on Linux (tetrix-lab is the first) as a systemd user service. One script does both: [`install/install.sh`](../install/install.sh).

**On a Mac, Oby.app runs obid itself** (the owner's decision of 2026-10-18): the app carries it (`Contents/Helpers/obid`, with its plug-ins and web app in `Contents/Resources/obid`) and registers it as a login item, `com.deskree.oby.obid`, when Settings › Runner is on **This Mac**. That obid runs `obid serve` with no `--config`: it uses `~/Library/Application Support/Oby/obid/config.json`, the file this script writes, and writes it the first time from what it finds on the Mac (Claude Code, Codex when it's there, telemetry off). Unlike this script's configuration, that one turns obid's gateway on (`"gateway": "127.0.0.1:8810"`): it listens on loopback only, and phones reach it only through what the owner puts in front of it (`tailscale serve`), as runner-api.md's "obid only: the gateway" says; its home is the `Runner` folder below, and it logs to `~/Library/Logs/obid.log`. It updates with the app. Nothing on this page is needed on a Mac any more. A Mac where this script installed obid keeps it running until Settings › Runner › **Move into Oby…**: the app stops the script's launch agent (`launchctl bootout`; if that fails, nothing else changes and it says so), takes out of `config.json` the `bundledPlugins` and `web` that point into the script's own folder (so the app's obid serves its signed copies), removes `~/Library/LaunchAgents/com.deskree.obid.plist`, and registers its own (`com.deskree.oby.obid`, never install.sh's label: macOS's background-task records tie a label to the file that first used it, and an app agent under it then never starts), with the same configuration, home, jobs and token (only when that agent used the default `config.json`; otherwise the app says to move the file first). The app also unregisters the Swift runner (`oby-runner`) an older Oby registered, which wanted the same ports. This script stays for Linux, and for a second obid beside the app's.

It needs no root, and run as root with another user's `HOME` (`sudo -E`) it refuses, since it would leave root's files in their home. Root in its own home (a container's `/root`) is fine. It runs as you, with the Claude Code, Codex and GitHub logins you already have; Oby never reads them ([AGENTS.md](../AGENTS.md)).

**Phone pairing** is available through obid's loopback gateway and `tailscale serve` ([below](#the-token-and-how-the-apps-find-obid-440)). The apps' **Settings › Server** (This Mac or a remote server) is not here yet. There is also no `.pkg` or Homebrew formula yet: a package has to be signed and notarized with Deskree's Developer ID on the release Mac ([release.md](release.md)), which is the user's step. The script does the same job without one.

## Install

```sh
curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh
```

The same line on a Mac and on Linux. It downloads `obid-<system>.tar.gz` from `downloads.oby.deskree.com/obid` and its `.sha256`, over https only (redirects too), and installs nothing if they don't match. A checksum from the same host catches a broken download, not a forged one: signed archives come before the first release. (That host is where the appcast already lives, [release.md](release.md); **nothing is published there yet**, so until the first release, build the archive yourself, below.)

Options, after `sh -s --` when piped: `--owner ID` (the id your Sphere knows you by; your user name if left out), `--listen 127.0.0.1:PORT` (7777 if left out), `--home DIR`, `--prefix DIR`, `--config FILE`, `--service NAME`, `--archive FILE [--sha256 HEX]` (install from a file instead of downloading), `--from URL` (another place to download from: an `https://` address, or an `http://` one with `--sha256`, and then the digest you give is the one checked and the server's `.sha256` isn't fetched), `--no-wait` (start the service without checking that obid answers). `--listen` is `127.0.0.1` and a port from 1 to 65535, nothing else.

### A second obid beside the first, or a test

`--service` names the service: the launchd label on a Mac (`com.deskree.obid` if left out, with its log in `~/Library/Logs/<label>.log`), the systemd unit on Linux (`obid`, so `obid.service`). Give a second obid its own `--service`, `--prefix`, `--home`, `--config` and `--listen`, and nothing of the first is read, written, stopped or started. Uninstall it with the same `--service`, `--prefix` and `--config`:

```sh
sh install/install.sh --archive obid-macos-arm64.tar.gz --service com.deskree.obid.test \
  --prefix /tmp/obid-test/opt --home /tmp/obid-test/home --listen 127.0.0.1:7895
sh install/install.sh uninstall --service com.deskree.obid.test --prefix /tmp/obid-test/opt --purge
```

A second obid on a Mac isn't **This Mac**: the app looks only at `127.0.0.1:7777` and the `Runner` folder.

### From a checkout, before there is a release

```sh
sh install/package.sh          # builds obid, the web app is taken from apps/web/dist if built
sh install/install.sh --archive build/obid/obid-linux-x86_64.tar.gz   # the name says your system
```

`package.sh` needs Rust ([core/](../core)); run `npm run build` in `apps/web` first if you want the web app at `/app/`. It uploads nothing.

### On Linux, first

obid runs every agent in [bubblewrap](https://github.com/containers/bubblewrap) with `slirp4netns`, and without them no job starts. The installer checks both before it changes anything, and when one is missing it stops and says what to run, for your distribution:

```sh
sudo apt install bubblewrap slirp4netns     # Debian, Ubuntu (use Ubuntu's own package: its AppArmor profile lets bubblewrap make the namespaces)
sudo dnf install bubblewrap slirp4netns     # Fedora
sudo pacman -S bubblewrap slirp4netns       # Arch
```

Then run the install line again. The installer also needs `systemctl` (systemd), `tar`, `od`, `mktemp` and `curl` (only to download or to check that obid answers).

### What it does

1. Puts obid in `--prefix`: `bin/obid`, and `share/plugins/` and `share/web/` (the plug-ins and the web app it ships; the configuration points at them). What it makes there, and the service file, only you can change (0755 folders and program, 0644 files), whatever your umask.
2. Makes obid's **home** (mode 0700) and **`home/api-token`** (mode 0600, 64 hex characters from `/dev/urandom`), where [runner-api.md](runner-api.md) ("obid only: configuration") says obid keeps its token. It is made straight into the file and read back from the file: it is never an argument or an environment variable of any command the script runs, never printed, and not in the service file or the configuration ([ARCHITECTURE.md](ARCHITECTURE.md) 5.3). A token already there is kept. The installer refuses to run when `OBID_API_TOKEN` is set, as obid does.
3. Writes `config.json` unless there is one (an edited one is never overwritten): `listen` `127.0.0.1:7777`, `home`, `owner`, Claude Code as the `claude` command with its default login (and Codex when your login shell finds `codex`; obid finds both on your login shell's `PATH`, as the apps do), `bundledPlugins` and `web` in the prefix, and `telemetry` off. No repositories are listed: add them under `repos` ([runner-api.md](runner-api.md)). **When there is a `config.json`, its `home` and `listen` are the ones used**: the token is made in that home, and the installer asks obid on that port. A `--home` or `--listen` that says otherwise stops it before anything changes.
4. Installs the service, starts it, and asks it `GET /v1/status` with the token (sent from a file, not an argument, and never through a proxy: curl would otherwise send even `127.0.0.1` through `http_proxy`) until it answers `"engine": "obid"`, so a port held by something else, like the Swift runner, is reported at once instead of looking like success.

| | Linux | macOS |
| --- | --- | --- |
| Program | `~/.local/opt/obid` | `~/Library/Application Support/Oby/obid` |
| Configuration | `~/.config/obid/config.json` | `~/Library/Application Support/Oby/obid/config.json` |
| **Home** (jobs, clones, worktrees, `api-token`) | `~/.local/share/obid` | `~/Library/Application Support/Oby/Runner` |
| Service | `~/.config/systemd/user/obid.service` | `~/Library/LaunchAgents/com.deskree.obid.plist` |
| Log | `journalctl --user -u obid` | `~/Library/Logs/obid.log` |

`--service`, `--prefix`, `--home` and `--config` change these; with `--service`, a Mac log is `~/Library/Logs/<label>.log`.

On a Mac the home is the folder the Mac app already reads `api-token` from for **This Mac** ([runner-api.md](runner-api.md), "The Mac app on the same Mac"), so the app finds obid without anything to set. On tetrix-lab give it a disk of its own, for example `--home /srv/nvme/obid`.

**The Linux service** survives a reboot because the installer turns on *lingering* (`loginctl enable-linger`), which starts your user's services at boot with nobody logged in. If that is refused it says so and prints `sudo loginctl enable-linger <you>`; until then obid runs only while you are logged in.

```ini
[Service]
# <prefix> and <config> are the absolute paths in the table above.
ExecStart="<prefix>/bin/obid" serve --config "<config>"
UnsetEnvironment=OBID_API_TOKEN
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
# Stopping it ends everything it started.
KillMode=control-group

[Install]
WantedBy=default.target
```

**The Mac service** is a launch agent: `RunAtLoad`, and `KeepAlive` when it exits with an error, with its output in `~/Library/Logs/obid.log`. It starts when you log in.

### Check it

```sh
journalctl --user -u obid -n 20        # Linux; on a Mac: tail ~/Library/Logs/obid.log
systemctl --user status obid           # Linux
```

On a Mac, open Oby: Settings › Runner shows **This Mac** connected. On Linux, from your own Mac, tunnel to it and open the web app obid serves:

```sh
ssh -L 7780:127.0.0.1:7777 tetrix-lab      # leave it open
open http://127.0.0.1:7780/app/            # signs in with the token in ~/.local/share/obid/api-token on tetrix-lab
```

## Update

obid doesn't update itself yet (#456). To update, run the install line again, or `install.sh --archive` with a newer archive. It stops the service, replaces the program, plug-ins and web app in the prefix, and starts it again. Your home, token and `config.json` are kept. `obid --version` says what is installed. An archive older than the obid already there installs too, with a warning: that is how you roll back.

One thing an update does not do: the plug-ins obid ships are copied into `home/plugins/<id>` only when that folder is missing, so a plug-in you already have there is not replaced ([runner-api.md](runner-api.md), `bundledPlugins`). Delete `home/plugins/<id>` to take the new copy (it is installed disabled again).

A job running when you update is carried on after the restart, as after any restart ([runner-api.md](runner-api.md), "After any restart").

## Uninstall

```sh
curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh -s -- uninstall      # or: sh install/install.sh uninstall
```

It stops and disables the service (on Linux: `systemctl --user disable --now`; on a Mac: `launchctl bootout`), removes the service file, ends any process still running from the prefix (a job that left its session), removes the program, plug-ins and web app, and says if anything is still running. It **keeps** your home (jobs, clones, the token) and `config.json`, so installing again picks up where you were.

To remove those too: `uninstall --purge`. It deletes the home named in `config.json` (or `--home`), the configuration and, on a Mac, the log, and prints the folder first. It deletes a folder only when it is obid's: it holds a regular `api-token` file, and where it really is (links and `..` resolved) it is not `/`, your home folder, or a folder your home folder is in. Otherwise it refuses before it stops anything, and the folder is yours to delete. It also refuses a home that holds `oby.sqlite`: on a Mac the `Runner` folder can be the Swift runner's too, and its data isn't obid's to delete. Then uninstall without `--purge` and delete obid's own files there by hand: `api-token`, `jobs/*.json`, `clones/`, `worktrees/`, `keys/`, `logs/`, `failures/`, `plugins/`, `plugin-data/`, `vault/`, `settings.json`, `permissions.json` and `approvals.json` ([runner-api.md](runner-api.md), "obid only: configuration"). Leave `devices.json` and `cleared.json`: the Swift runner reads the same files. It does not touch the vault's Keychain items on a Mac (`obid vault --config <path> remove NAME` does that, one at a time), your logins, or lingering (other services of yours may use it; `sudo loginctl disable-linger <you>` turns it off).

## Migrating from the Swift runner

The Swift runner (`oby-runner`: the Mac app's login item, and tetrix-lab's `oby-runner` user service) and obid serve the same API, so the apps work against either. Think of it as moving house rather than renovating: obid doesn't open the Swift runner's database (`oby.sqlite`), it starts with its own files, and you carry over the few things it can read as they are. Nothing of the Swift runner's is changed, so going back is stopping one and starting the other.

### The token, and how the apps find obid (#440)

obid's API token is `home/api-token` (0600, in a 0700 home). The installer makes it there, it is never in an argument, an environment variable, the service file or `config.json`, and the installer never prints it.

- **The Mac app** (Settings › Runner › **This Mac**) looks at `127.0.0.1:7777` and reads the token straight from `~/Library/Application Support/Oby/Runner/api-token`: that is why the installer's home on a Mac is that folder. It takes the file only when it's a regular file of yours with no group or other permissions, at most 4096 bytes, of at least 32 visible characters. When there is no usable file, or the server answers it with `401`, it falls back to the Swift runner's Keychain item (`com.deskree.oby.runner`, account `token`). So the same app reaches whichever of the two is running, with nothing to set ([runner-api.md](runner-api.md), "The Mac app on the same Mac").
- **The web app** obid serves at `/app/` signs in with that same token, pasted once into the browser on that machine.
- **On tetrix-lab** the token is in obid's home there (`~/.local/share/obid/api-token`, or the `--home` you gave). The gateway has shipped (#446): set `"gateway": "127.0.0.1:8810"` in `config.json`, restart obid, and expose that gateway on the tailnet with `tailscale serve --bg --https=8443 http://127.0.0.1:8810`. Make an invitation with `POST /v1/pairing/invite` on the loopback API using the API token and `url` set to `https://<the server's tailnet name>:8443`. On the iPhone, paste the invitation JSON (`url`, `link` as an object with `name` and `hostname`, and `secret`) in Settings › Your Mac to pair; it is good for two minutes and once, and the phone then uses its own device token. The gateway stays on `127.0.0.1`, with no LAN listener or Bonjour advertisement ([runner-api.md](runner-api.md#obid-only-the-gateway)). obid still has no Watch API. SSH remains an option for the web app (`ssh -L 7780:127.0.0.1:7777 tetrix-lab`, above).

### What moves, what you redo, what stays behind

**Moves, because obid reads the same file:**

| What | Where | Notes |
| --- | --- | --- |
| Secrets in the vault | Mac: the Keychain, service `com.deskree.oby.runner.vault`. Linux: `home/vault/secrets.json` | On a Mac the same items, when obid's home is the Mac app's `Runner` folder (what the installer uses). On Linux copy `vault/secrets.json` into the new home (folder 0700, file 0600), or add them again with `obid vault --config <path> add NAME`. |
| Phones that may approve publishing | `home/devices.json` | Copy it into the new home. Without it each device registers again (open pairing: `touch home/pairing`). |
| When Clear done was last pressed | `home/cleared.json` | Copy it, or ignore it. |
| Your logins | Claude Code, Codex, `gh`: each tool's own | Nothing to move; obid runs as the same user. |

**You redo by hand:**

- **Accounts.** The Swift runner's `accounts.json` (`[{"id", "agent", "name", "payer", "home"}]`) becomes obid's `config.json`: one entry per account under `agents.claude`, `agents.codex` or `agents.cursor`, `{"id": …, "name": …, "configDir": <its home, or null for the tool's default login>}`. `payer` has no place in obid. A Cursor account needs its `configDir` ([runner-api.md](runner-api.md), "obid only: configuration"). The account folders (`accounts/<id>`) can stay where they are; point `configDir` at them, and the logins in them still work.
- **Repositories.** List them under `repos` in `config.json`, each with its `check`. obid makes its own clones in `home/clones`; the Swift runner's `repos/` isn't read.
- **Settings.** The jobs limit (`maxRunning`), Settings › Permissions and Settings › Models live in the Swift runner's `oby.sqlite` and `~/.config/oby-runner.plist`; obid keeps its own in `home/settings.json` and `home/permissions.json`. Set them again in the apps.
- **The owner.** On tetrix-lab the Swift runner's owner is your Tailscale login (`OBY_OWNER`); obid's `owner` is the id your Sphere knows you by (`--owner`).
- **Plug-ins and connections** are obid's own; there is nothing to bring.

**Doesn't move, and stays behind:**

- **Jobs, the inbox, the conversation, failure records and past results.** They are in `oby.sqlite` and `jobs/`. Finish or publish what you need before you switch; obid starts with an empty list. Keep the old folder until you are sure (the Swift runner is frozen, but its data is yours).
- **Decisions.** The rules saved for a repository ("always") and what the Swift runner learned are in `oby.sqlite`; obid's remembered decisions ([runner-api.md](runner-api.md), "obid only: remembered decisions") start empty and fill as you answer.
- **The GitHub App** (tetrix-lab's `OBY_GITHUB_APP_ID`): obid publishes with your own `gh` login.
- **Merging.** obid never merges; that stays a person's step.

### On a Mac

1. Finish, publish or cancel the jobs you care about on the Swift runner.
2. Stop it so port 7777 is free. The Swift runner is Oby's login item (`com.deskree.oby.runner`): choosing **This Mac** in Settings › Runner registers it, so it starts at every login, and choosing **Remote** unregisters it. Choose Remote now. `lsof -nP -iTCP:7777 -sTCP:LISTEN` should print nothing.
3. Run the installer with no `--home`. Its home is the `Runner` folder the Swift runner may also use: obid keeps its jobs as `jobs/<id>.json` and ignores the Swift runner's `jobs/<id>/` folders beside them, uses `clones/` and `worktrees/` of its own, and leaves `oby.sqlite` untouched.
4. Write the accounts and repositories into `config.json` (`~/Library/Application Support/Oby/obid/config.json`), then `launchctl kickstart -k gui/$(id -u)/com.deskree.obid`.
5. In Settings › Runner choose **This Mac** again: the app follows `127.0.0.1:7777` and finds obid's token. Choosing it also registers the Swift runner's login item again, and at the next login both would race for port 7777, so turn that item off in System Settings › General › Login Items & Extensions (under Allow in the Background, Oby's runner) until the app knows about obid. **This Mac** should be connected, and `GET /v1/status` says `"engine": "obid"`.

**If you already ran obid by hand**, from `~/Library/Application Support/Oby/obid/config.json` with its home in `obid/home`: the installer keeps that `config.json` and uses its home and port (step 3 of What it does). The app finds a token only in the `Runner` folder, though, so for **This Mac** stop that obid, point `home` in `config.json` at `~/Library/Application Support/Oby/Runner` (absolute), copy `devices.json`, `cleared.json`, `settings.json` and `permissions.json` across, and install. Let obid make its clones and worktrees again rather than moving them: a git worktree remembers where its clone was.

**Going back:** `sh install/install.sh uninstall` (it keeps obid's home and `config.json`), then start the Swift runner again: turn its login item back on in System Settings, or choose Remote and then This Mac in Settings › Runner, which registers it. The `api-token` file obid left in `Runner` doesn't get in the way: the Swift runner answers it `401`, and the app falls back to the Keychain token.

### On tetrix-lab

The Swift runner there is `~/.config/systemd/user/oby-runner.service`, with its home in `/srv/nvme/oby` and a Watch API tunnel (`oby-cloudflared`) on port 7778.

1. Finish, publish or cancel the jobs you care about.
2. Install obid beside it, on a port of its own and a home on the same disk, and try it over SSH while the Swift runner still serves the phone:

   ```sh
   curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh -s -- \
     --home /srv/nvme/obid --listen 127.0.0.1:7787 --owner <your Sphere id>
   ```

   (or `sh install/install.sh --archive …` from a checkout, before there is a release).
3. Copy what moves from `/srv/nvme/oby` (`vault/secrets.json`, `devices.json`, `cleared.json`: folders 0700, files 0600) into `/srv/nvme/obid`, and write the accounts and repositories into `~/.config/obid/config.json`. `systemctl --user restart obid`.
4. When you are happy with it, switch: `systemctl --user disable --now oby-runner`, set `listen` to `127.0.0.1:7777` in `config.json`, and `systemctl --user restart obid`. `oby-cloudflared` then has nothing to forward to; stop it too (`systemctl --user disable --now oby-cloudflared`) until the Watch has a way to obid.
5. `systemctl --user is-enabled obid` says `enabled` and `loginctl show-user $(id -un) -p Linger` says `Linger=yes`: it starts at boot with nobody logged in.

**Going back:** `systemctl --user disable --now obid` (or `sh install.sh uninstall`, which keeps `/srv/nvme/obid` and `config.json`), then `systemctl --user enable --now oby-runner oby-cloudflared`. `/srv/nvme/oby` was only read, never written, so the Swift runner finds everything as it left it.

**When you are sure**, remove what is left of the Swift runner: on Linux `~/.local/bin/oby-runner`, `~/.config/systemd/user/oby-runner.service` (and its `.d` folder), and `/srv/nvme/oby`; on a Mac the Swift runner's files in the `Runner` folder (`oby.sqlite`, `repos/`, its `jobs/<id>/` folders, `accounts.json`).
