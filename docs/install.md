# Installing obid (#585)

`obid` is Oby's server: it plans, runs jobs and keeps their results, and the apps talk to it over the runner API ([runner-api.md](runner-api.md)). This page is how to put it on a machine as a service that starts by itself: on a Mac as a launchd agent, on Linux (tetrix-lab is the first) as a systemd user service. One script does both: [`install/install.sh`](../install/install.sh).

It needs no root. It runs as you, with the Claude Code, Codex and GitHub logins you already have; Oby never reads them ([AGENTS.md](../AGENTS.md)).

**Not here yet:** the apps' **Settings › Server** (This Mac or a remote server) and pairing a Mac or phone with a remote obid. They need the LAN gateway and its pairing (#446), so they come next. Until then the apps reach the obid on their own Mac, and a remote one is reached over an SSH tunnel (below). There is also no `.pkg` or Homebrew formula yet: a package has to be signed and notarized with Deskree's Developer ID on the release Mac ([release.md](release.md)), which is the user's step. The script does the same job without one.

## Install

```sh
curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh
```

The same line on a Mac and on Linux. It downloads `obid-<system>.tar.gz` from `downloads.oby.deskree.com/obid` and its `.sha256`, and installs nothing if they don't match. (That host is where the appcast already lives, [release.md](release.md); **nothing is published there yet**, so until the first release, build the archive yourself, below.)

Options, after `sh -s --` when piped: `--owner ID` (the id your Sphere knows you by; your user name if left out), `--listen 127.0.0.1:PORT` (7777 if left out), `--home DIR`, `--prefix DIR`, `--archive FILE [--sha256 HEX]` (install from a file instead of downloading), `--from URL` (another place to download from), `--no-wait`.

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

1. Puts obid in `--prefix`: `bin/obid`, and `share/plugins/` and `share/web/` (the plug-ins and the web app it ships; the configuration points at them).
2. Makes obid's **home** (mode 0700) and **`home/api-token`** (mode 0600, 64 hex characters from `/dev/urandom`), where [runner-api.md](runner-api.md) ("obid only: configuration") says obid keeps its token. It is made straight into the file and read back from the file: it is never an argument or an environment variable of any command the script runs, never printed, and not in the service file or the configuration ([ARCHITECTURE.md](ARCHITECTURE.md) 5.3). A token already there is kept. The installer refuses to run when `OBID_API_TOKEN` is set, as obid does.
3. Writes `config.json` unless there is one (an edited one is never overwritten): `listen` `127.0.0.1:7777`, `home`, `owner`, Claude Code as the `claude` command with its default login (and Codex when `codex` is on your `PATH`; the command is found on your login shell's `PATH`, as for the apps), `bundledPlugins` and `web` in the prefix, and `telemetry` off. No repositories are listed: add them under `repos` ([runner-api.md](runner-api.md)).
4. Installs the service, starts it, and asks it `GET /v1/status` with the token (sent from a file, not an argument) until it answers `"engine": "obid"`, so a port held by something else, like the Swift runner, is reported at once instead of looking like success.

| | Linux | macOS |
| --- | --- | --- |
| Program | `~/.local/opt/obid` | `~/Library/Application Support/Oby/obid` |
| Configuration | `~/.config/obid/config.json` | `~/Library/Application Support/Oby/obid/config.json` |
| **Home** (jobs, clones, worktrees, `api-token`) | `~/.local/share/obid` | `~/Library/Application Support/Oby/Runner` |
| Service | `~/.config/systemd/user/obid.service` | `~/Library/LaunchAgents/com.deskree.obid.plist` |
| Log | `journalctl --user -u obid` | `~/Library/Logs/obid.log` |

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

obid doesn't update itself yet (#456). To update, run the install line again, or `install.sh --archive` with a newer archive. It stops the service, replaces the program, plug-ins and web app in the prefix, and starts it again. Your home, token and `config.json` are kept. `obid --version` says what is installed.

One thing an update does not do: the plug-ins obid ships are copied into `home/plugins/<id>` only when that folder is missing, so a plug-in you already have there is not replaced ([runner-api.md](runner-api.md), `bundledPlugins`). Delete `home/plugins/<id>` to take the new copy (it is installed disabled again).

A job running when you update is carried on after the restart, as after any restart ([runner-api.md](runner-api.md), "After any restart").

## Uninstall

```sh
curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh -s -- uninstall      # or: sh install/install.sh uninstall
```

It stops and disables the service (on Linux: `systemctl --user disable --now`; on a Mac: `launchctl bootout`), removes the service file, ends any process still running from the prefix (a job that left its session), removes the program, plug-ins and web app, and says if anything is still running. It **keeps** your home (jobs, clones, the token) and `config.json`, so installing again picks up where you were.

To remove those too: `uninstall --purge`. It deletes the home named in `config.json` and the configuration, and prints the folder first. It does not touch the vault's Keychain items on a Mac (`obid vault --config <path> remove NAME` does that, one at a time), your logins, or lingering (other services of yours may use it; `sudo loginctl disable-linger <you>` turns it off).

## Migrating from the Swift runner

The Swift runner (`oby-runner`: the Mac app's login item, and tetrix-lab's `oby-runner` service) and obid serve the same API, so the apps work against either. They don't share a database: obid keeps its jobs as files in its home, the Swift runner in `oby.sqlite`. So nothing is converted; this is what carries over and what doesn't.

**Moves, because obid reads the same file:**

| What | Where | Notes |
| --- | --- | --- |
| Secrets in the vault | Mac: the Keychain, service `com.deskree.oby.runner.vault`. Linux: `home/vault/secrets.json` | On a Mac the same items, when obid's home is the Mac app's `Runner` folder (what the installer uses). On Linux copy `vault/secrets.json` into the new home (folder 0700, file 0600), or add them again with `obid vault --config <path> add NAME`. |
| Phones that may approve publishing | `home/devices.json` | Copy it into the new home. Without it each device registers again (open pairing: `touch home/pairing`). |
| When Clear done was last pressed | `home/cleared.json` | Copy it, or ignore it. |
| Your logins | Claude Code, Codex, `gh`: each tool's own | Nothing to move; obid runs as the same user. |

**You redo by hand:**

- **Accounts.** The Swift runner's `accounts.json` (`[{"id", "agent", "name", "payer", "home"}]`) becomes obid's `config.json`: one entry per account under `agents.claude`, `agents.codex` or `agents.cursor`, `{"id": …, "name": …, "configDir": <its home, or null for the tool's default login>}`. `payer` has no place in obid. A Cursor account needs its `configDir` ([runner-api.md](runner-api.md), "obid only: configuration"). The account folders (`accounts/<id>`) can stay where they are; point `configDir` at them, and the logins in them still work.
- **Repositories.** List them under `repos` in `config.json`. obid makes its own clones in `home/clones`; the Swift runner's `repos/` isn't read.
- **Settings.** The jobs limit (`maxRunning`), Settings › Permissions and Settings › Models live in the Swift runner's `oby.sqlite` and `~/.config/oby-runner.plist`; obid keeps its own in `home/settings.json` and `home/permissions.json`. Set them again in the apps.
- **Plug-ins and connections** are obid's own; there is nothing to bring.

**Doesn't move, and stays behind:**

- **Jobs, the inbox, the conversation, failure records and past results.** They are in `oby.sqlite` and `jobs/`. Finish or publish what you need before you switch; obid starts with an empty list. Keep the old folder until you are sure (the Swift runner is frozen, but its data is yours).
- **Decisions.** The rules saved for a repository ("always") and what the Swift runner learned are in `oby.sqlite`; obid's remembered decisions ([runner-api.md](runner-api.md), "obid only: remembered decisions") start empty and fill as you answer.
- **Merging.** obid never merges; that stays a person's step.

**Steps**

1. Finish, publish or cancel the jobs you care about on the Swift runner.
2. Stop it so port 7777 is free: on a Mac quit Oby's runner (Settings › Runner, or quit the app; `lsof -nP -iTCP:7777 -sTCP:LISTEN` should print nothing). On tetrix-lab: `systemctl --user disable --now oby-runner`. Or, to run both for a while on tetrix-lab, install obid with `--listen 127.0.0.1:7778`.
3. Run the installer. On a Mac its home is the Swift runner's own folder: obid keeps its jobs as `jobs/<id>.json` and ignores the Swift runner's `jobs/<id>/` worktree folders beside them, uses `clones/` and `worktrees/` of its own, and leaves `oby.sqlite` untouched. On Linux the default home is a new folder, so nothing is shared.
4. Copy what moves (table above) and write the accounts and repositories into `config.json`, then `systemctl --user restart obid` (Linux) or `launchctl kickstart -k gui/$(id -u)/com.deskree.obid` (Mac).
5. Open the app: **This Mac** should be connected. `GET /v1/status` says `"engine": "obid"`.
6. When you are sure, remove what is left of the Swift runner: on Linux `~/.local/bin/oby-runner`, `~/.config/systemd/user/oby-runner.service` and its old home; on a Mac the old files in the `Runner` folder (`oby.sqlite`, `repos/`, the worktree folders in `jobs/`, `accounts.json`).

On tetrix-lab the Swift runner is published on the tailnet by `tailscale serve --https=8443` and trusts the `Tailscale-User-Login` header. obid does not: it answers only its token, on loopback. Letting the apps pair with it from outside is the next piece of this work (#446).
