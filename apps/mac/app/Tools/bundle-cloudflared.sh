#!/bin/zsh
# Bundles cloudflared with Oby (#285): Contents/MacOS/cloudflared, universal, signed with the app's
# identity and the hardened runtime, so it's notarized with the app. The release is pinned and
# checked against its SHA-256; the download is cached under ~/Library/Caches, never in the
# repository. Run by the "Bundle cloudflared" build phase of the Oby target (apps/Oby.xcodeproj).
set -euo pipefail

VERSION=2026.10.0
typeset -A SHA256
SHA256[arm64]=a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70
SHA256[amd64]=903845b81828c8cb3c5d13d816a2de71c06a3da5785469df8eb0e1b736d92f9f
cache="${CLOUDFLARED_CACHE:-$HOME/Library/Caches/com.deskree.oby/cloudflared}/$VERSION"

# The release's binary for one architecture, downloaded once and checked.
fetch() {
  local arch=$1 out="$cache/cloudflared-$1"
  [[ -x "$out" ]] && return
  mkdir -p "$cache"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "$tmp/cloudflared.tgz" \
    "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/cloudflared-darwin-$arch.tgz"
  echo "${SHA256[$arch]}  $tmp/cloudflared.tgz" | shasum -a 256 -c - > /dev/null
  tar -xzf "$tmp/cloudflared.tgz" -C "$tmp" cloudflared
  chmod 755 "$tmp/cloudflared"
  mv "$tmp/cloudflared" "$out"
  rm -rf "$tmp"
}

fetch arm64
fetch amd64

dest="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/cloudflared"
mkdir -p "$(dirname "$dest")"
rm -f "$dest"
lipo -create -output "$dest" "$cache/cloudflared-arm64" "$cache/cloudflared-amd64"

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$dest"
