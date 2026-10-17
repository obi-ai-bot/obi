#!/bin/sh
# Installs obid as a service on this machine, or removes it (docs/install.md, #585):
#
#   curl -fsSL https://downloads.oby.deskree.com/obid/install.sh | sh
#   sh install.sh [install] [--archive FILE [--sha256 HEX]] [--from URL] [--owner ID]
#                  [--home DIR] [--prefix DIR] [--listen ADDR] [--no-wait]
#   sh install.sh uninstall [--prefix DIR] [--purge]
#
# On Linux it installs a systemd user service (and turns lingering on, so it starts at boot and
# survives a logout); on macOS a launchd agent. Either way it:
#   - checks what obid needs (Linux: bubblewrap and slirp4netns) and, when one is missing, stops
#     and says how to install it;
#   - puts obid in --prefix, with the plug-ins and the web app it ships;
#   - makes obid's home (0700) and home/api-token (0600) where docs/runner-api.md says obid keeps
#     them, and writes config.json when there is none;
#   - starts the service and asks it who it is.
# The token is made by this script straight into the file and read back from it: it is never an
# argument or an environment variable of any command run here, and it is never printed
# (docs/ARCHITECTURE.md 5.3). Running it again updates obid and keeps the home, the token and the
# configuration. It needs no root.
set -eu

BASE_URL="https://downloads.oby.deskree.com/obid"
LABEL="com.deskree.obid"

say() { printf '%s\n' "$*"; }
warn() { printf 'obid install: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is needed and isn't installed."; }

command_word="install"
case "${1:-}" in
install | uninstall) command_word="$1"; shift ;;
esac

archive="" sha256="" from="$BASE_URL" owner="" obid_home="" prefix="" listen="127.0.0.1:7777"
wait_for_obid=1 purge=0
while [ $# -gt 0 ]; do
  case "$1" in
  --archive) archive="${2:?--archive needs a file}"; shift 2 ;;
  --sha256) sha256="${2:?--sha256 needs a digest}"; shift 2 ;;
  --from) from="${2:?--from needs a URL}"; shift 2 ;;
  --owner) owner="${2:?--owner needs an id}"; shift 2 ;;
  --home) obid_home="${2:?--home needs a folder}"; shift 2 ;;
  --prefix) prefix="${2:?--prefix needs a folder}"; shift 2 ;;
  --listen) listen="${2:?--listen needs an address}"; shift 2 ;;
  --no-wait) wait_for_obid=0; shift ;;
  --purge) purge=1; shift ;;
  *) die "unknown option $1 (see the top of this script)." ;;
  esac
done

# obid refuses to start with its token in its environment; so does this script.
[ -z "${OBID_API_TOKEN+set}" ] || die "OBID_API_TOKEN is set. obid takes its token only from home/api-token, never from its environment, where other processes can read it: unset it (the installer makes the file)."

case "$(uname -s)" in
Linux) kind="linux" ;;
Darwin) kind="macos" ;;
*) die "$(uname -s) isn't supported: obid runs on macOS and Linux." ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch="x86_64" ;;
aarch64 | arm64) if [ "$kind" = macos ]; then arch="arm64"; else arch="aarch64"; fi ;;
*) die "$(uname -m) isn't supported." ;;
esac
target="$kind-$arch"
uid="$(id -u)"
user="$(id -un)"
[ -n "${HOME:-}" ] || die "HOME isn't set."

if [ "$kind" = linux ]; then
  config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  [ -n "$prefix" ] || prefix="$HOME/.local/opt/obid"
  config_dir="$config_home/obid"
  [ -n "$obid_home" ] || obid_home="${XDG_DATA_HOME:-$HOME/.local/share}/obid"
  unit="$config_home/systemd/user/obid.service"
else
  support="$HOME/Library/Application Support/Oby"
  [ -n "$prefix" ] || prefix="$support/obid"
  config_dir="$prefix"
  # The folder the Mac app reads api-token from for "This Mac" (docs/runner-api.md).
  [ -n "$obid_home" ] || obid_home="$support/Runner"
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  log="$HOME/Library/Logs/obid.log"
fi
config="$config_dir/config.json"
token_file="$obid_home/api-token"

# Paths go into a JSON file, a systemd unit and a property list: keep them to characters that mean
# the same in all three.
plain() {
  case "$2" in
  /*) ;;
  *) die "$1 must be an absolute path, not $2." ;;
  esac
  case "$2" in
  *[!A-Za-z0-9_./\ +@=-]*) die "$1 ($2) may hold only letters, digits, spaces and _ . / + @ = -." ;;
  esac
}
plain "--prefix" "$prefix"
plain "--home" "$obid_home"
plain "the configuration folder" "$config_dir"

systemctl_user() {
  # Over ssh there is often no XDG_RUNTIME_DIR, and systemctl --user can't find the user manager.
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$uid" ]; then
    XDG_RUNTIME_DIR="/run/user/$uid"
    export XDG_RUNTIME_DIR
  fi
  systemctl --user "$@"
}

stop_service() {
  if [ "$kind" = linux ]; then
    if [ -e "$unit" ]; then systemctl_user disable --now obid.service >/dev/null 2>&1 || true; fi
  else
    launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  fi
}

# Whatever of obid's is still running from $prefix, ended: the service's own stop takes its
# children with it; this catches the rest (a job that left its session).
end_leftovers() {
  command -v pgrep >/dev/null 2>&1 || { warn "pgrep isn't installed, so I can't check that nothing of obid's is left running."; return 0; }
  pattern="^$prefix/bin/obid( |\$)"
  for signal in TERM KILL; do
    pids="$(pgrep -u "$uid" -f "$pattern" || true)"
    [ -n "$pids" ] || return 0
    say "Ending what is still running from $prefix/bin/obid (SIGTERM first)."
    # shellcheck disable=SC2086
    kill -"$signal" $pids 2>/dev/null || true
    sleep 2
  done
  pids="$(pgrep -u "$uid" -f "$pattern" || true)"
  [ -z "$pids" ] || die "obid is still running (process $pids): end it by hand."
}

if [ "$command_word" = uninstall ]; then
  stop_service
  if [ "$kind" = linux ]; then
    rm -f "$unit"
    systemctl_user daemon-reload >/dev/null 2>&1 || true
  else
    rm -f "$plist"
  fi
  end_leftovers
  rm -f "$prefix/bin/obid" "$prefix/bin/obid.new"
  rm -rf "$prefix/share/plugins" "$prefix/share/web" "$prefix/share/plugins.new" "$prefix/share/web.new"
  rmdir "$prefix/bin" "$prefix/share" 2>/dev/null || true
  say "obid is stopped and removed from $prefix; the service is gone."
  if [ "$purge" = 1 ]; then
    # What to delete is what the configuration says obid's home is, never a guess.
    kept_home="$(sed -n 's/^ *"home": *"\([^"]*\)".*/\1/p' "$config" 2>/dev/null | head -n 1)"
    [ -n "$kept_home" ] || kept_home="$obid_home"
    case "$kept_home" in
    / | "$HOME" | "$HOME/" | "") die "Not deleting $kept_home: it isn't a folder of obid's." ;;
    esac
    say "Deleting obid's home $kept_home (jobs, clones, worktrees, the token, the vault file) and $config."
    rm -rf "$kept_home"
    rm -f "$config"
    rmdir "$config_dir" 2>/dev/null || true
  else
    say "Kept: $obid_home (jobs, clones, the token) and $config. 'uninstall --purge' deletes them."
  fi
  rmdir "$prefix" 2>/dev/null || true
  exit 0
fi

# ---- Install ----------------------------------------------------------------------------------

if [ "$kind" = linux ]; then
  missing=""
  for tool in bwrap slirp4netns; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    packages=""
    case "$missing" in *bwrap*) packages="bubblewrap" ;; esac
    case "$missing" in *slirp4netns*) packages="$packages slirp4netns" ;; esac
    packages="${packages# }"
    warn "obid runs every agent in bubblewrap with slirp4netns, and without them no job can start. Missing:$missing."
    if command -v apt-get >/dev/null 2>&1; then warn "Install them with: sudo apt install $packages"
    elif command -v dnf >/dev/null 2>&1; then warn "Install them with: sudo dnf install $packages"
    elif command -v pacman >/dev/null 2>&1; then warn "Install them with: sudo pacman -S $packages"
    elif command -v zypper >/dev/null 2>&1; then warn "Install them with: sudo zypper install $packages"
    elif command -v apk >/dev/null 2>&1; then warn "Install them with: sudo apk add $packages"
    else warn "Install your distribution's packages: $packages"
    fi
    die "Then run this again."
  fi
  if ! bwrap --unshare-user --ro-bind / / true >/dev/null 2>&1; then
    warn "bubblewrap is installed but can't make a sandbox here. On Ubuntu, use its own package (its AppArmor profile allows the namespaces); obid will say the same when a job starts."
  fi
  need systemctl
fi
need tar
need od
need mktemp
if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum "$1" | { read -r sum _; printf '%s\n' "$sum"; }; }
elif command -v shasum >/dev/null 2>&1; then digest() { shasum -a 256 "$1" | { read -r sum _; printf '%s\n' "$sum"; }; }
else die "sha256sum (or shasum) is needed and isn't installed."
fi

if [ -z "$owner" ]; then owner="$user"; fi
case "$owner" in
"" | *[!A-Za-z0-9_.@-]*) die "--owner ($owner) may hold only letters, digits and _ . @ -." ;;
esac
case "$listen" in
127.0.0.1:[0-9]*) ;;
*) die "--listen ($listen) must be an address on 127.0.0.1 with a port, like 127.0.0.1:7777." ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/obid-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM HUP

if [ -z "$archive" ]; then
  need curl
  say "Downloading obid-$target from $from"
  archive="$work/obid.tar.gz"
  curl -fsSL -o "$archive" "$from/obid-$target.tar.gz" || die "couldn't download $from/obid-$target.tar.gz."
  curl -fsSL -o "$work/obid.sha256" "$from/obid-$target.tar.gz.sha256" || die "couldn't download the checksum $from/obid-$target.tar.gz.sha256."
  read -r sha256 _ <"$work/obid.sha256" || true
  [ -n "$sha256" ] || die "the checksum file is empty."
fi
[ -f "$archive" ] || die "$archive isn't a file."
if [ -n "$sha256" ] && [ "$(digest "$archive")" != "$sha256" ]; then
  die "$archive doesn't match its checksum, so nothing was installed."
fi
mkdir "$work/new"
tar -xzf "$archive" -C "$work/new" || die "couldn't unpack $archive."
[ -x "$work/new/bin/obid" ] || die "$archive has no bin/obid."
version="$("$work/new/bin/obid" --version 2>/dev/null)" || die "the obid in $archive doesn't run on this machine."
say "Installing $version for $target."

stop_service

mkdir -p "$prefix/bin" "$prefix/share"
cp "$work/new/bin/obid" "$prefix/bin/obid.new"
chmod 755 "$prefix/bin/obid.new"
mv -f "$prefix/bin/obid.new" "$prefix/bin/obid"
for part in plugins web; do
  rm -rf "$prefix/share/$part.new"
  if [ -d "$work/new/share/$part" ]; then
    cp -R "$work/new/share/$part" "$prefix/share/$part.new"
    rm -rf "$prefix/share/$part"
    mv "$prefix/share/$part.new" "$prefix/share/$part"
  fi
done

# obid's home: only its owner may open it, and the token in it only its owner may read.
mkdir -p "$(dirname "$obid_home")"
[ -d "$obid_home" ] || mkdir "$obid_home"
chmod 700 "$obid_home"
if [ -e "$token_file" ]; then
  chmod 600 "$token_file"
  say "Kept the API token in $token_file."
else
  (
    umask 077
    head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' >"$token_file.new"
    printf '\n' >>"$token_file.new"
  )
  mv "$token_file.new" "$token_file"
  say "Made the API token in $token_file (0600)."
fi

mkdir -p "$config_dir"
if [ -e "$config" ]; then
  say "Kept your configuration $config."
else
  codex=""
  if command -v codex >/dev/null 2>&1; then
    codex=',
    "codex": {"bin": "codex", "accounts": [{"id": "codex", "name": "Codex", "configDir": null}]}'
  fi
  (
    umask 077
    cat >"$config.new" <<EOF
{
  "listen": "$listen",
  "home": "$obid_home",
  "owner": "$owner",
  "agents": {
    "claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]}$codex
  },
  "bundledPlugins": "$prefix/share/plugins",
  "web": "$prefix/share/web",
  "telemetry": false
}
EOF
  )
  mv "$config.new" "$config"
  say "Wrote $config (owner $owner)."
fi
command -v claude >/dev/null 2>&1 || warn "Claude Code isn't on this PATH. Install it and sign in as $user (claude auth login): obid runs the CLIs you already use."

if [ "$kind" = linux ]; then
  mkdir -p "$(dirname "$unit")"
  cat >"$unit.new" <<EOF
# obid, Oby's server (docs/install.md). Written by install/install.sh; running it again rewrites
# this file. obid reads its API token only from home/api-token: nothing secret is set here, and
# obid refuses to start with OBID_API_TOKEN in its environment.
[Unit]
Description=obid, Oby's server

[Service]
ExecStart="$prefix/bin/obid" serve --config "$config"
UnsetEnvironment=OBID_API_TOKEN
Restart=on-failure
RestartSec=5
# obid exits within 10 seconds of SIGTERM; stopping ends everything it started.
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=default.target
EOF
  mv "$unit.new" "$unit"
  systemctl_user daemon-reload || die "can't reach your systemd user manager. Log in as $user (not su or sudo) and run this again."
  systemctl_user enable --now obid.service || die "systemd couldn't start obid: systemctl --user status obid"
  if ! loginctl enable-linger "$user" 2>/dev/null; then
    warn "Couldn't turn on lingering, so obid starts only while you are logged in. Run: sudo loginctl enable-linger $user"
  fi
  where="journalctl --user -u obid"
else
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  cat >"$plist.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- obid, Oby's server (docs/install.md). Written by install/install.sh. obid reads its API token
     only from home/api-token: nothing secret is set here. -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$prefix/bin/obid</string>
		<string>serve</string>
		<string>--config</string>
		<string>$config</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>StandardOutPath</key>
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
EOF
  mv "$plist.new" "$plist"
  launchctl bootstrap "gui/$uid" "$plist" || die "launchd couldn't load $plist."
  where="tail $log"
fi

if [ "$wait_for_obid" = 1 ] && command -v curl >/dev/null 2>&1; then
  # Ask obid who it is, with the token in a file (curl -H @file), not in an argument. The Swift
  # runner answers on the same port, so the answer must say it is obid.
  header="$work/header"
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "$(cat "$token_file")" >"$header"
  )
  tries=0
  until curl -fsS -H "@$header" "http://$listen/v1/status" 2>/dev/null | grep -q '"engine" *: *"obid"'; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      die "obid didn't answer on http://$listen within 30 seconds. See: $where. If the Swift runner (Oby's login item) holds that port, stop it first (docs/install.md, Migrating)."
    fi
    sleep 1
  done
fi

say "obid is running on http://$listen as a service. Its API token is in $token_file."
say "Update: run this script again with a newer archive. Remove: sh install.sh uninstall. See docs/install.md."
