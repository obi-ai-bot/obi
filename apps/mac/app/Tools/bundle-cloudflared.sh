#!/bin/zsh
# Bundles cloudflared with Oby (#285): Contents/MacOS/cloudflared, universal, signed with the app's
# identity and the hardened runtime, so it's notarized with the app. The release is pinned and
# checked against its SHA-256 on every build; the download is cached under ~/Library/Caches, never
# in the repository. Run by the "Bundle cloudflared" build phase of the Oby target (apps/Oby.xcodeproj).
set -euo pipefail

# Only a full build carries it (OBY_FULL_BUILD=1, docs/release.md): Remote access is hidden in the
# launch build (AGENTS.md, "The launch build"). Without it, what an earlier full build left goes.
dest="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/cloudflared"
if [[ "${OBY_FULL_BUILD:-}" != 1 ]]; then rm -f "$dest"; exit 0; fi

VERSION=2026.10.0
typeset -A SHA256
SHA256[arm64]=a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70
SHA256[amd64]=903845b81828c8cb3c5d13d816a2de71c06a3da5785469df8eb0e1b736d92f9f
cache="${CLOUDFLARED_CACHE:-$HOME/Library/Caches/com.deskree.oby/cloudflared}/$VERSION"

# The release's archive for one architecture: downloaded once into the cache, but the cache is
# the user's to write, so every build copies it into a private folder and checks that copy against
# its pinned SHA-256 before cloudflared is taken out of it (a swapped file is never signed into the
# app).
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() {
  local arch=$1
  local tgz="$cache/cloudflared-darwin-$arch.tgz" copy="$work/cloudflared-$arch.tgz"
  mkdir -p "$cache"
  if [[ -f "$tgz" ]]; then cp "$tgz" "$copy"; fi
  if ! echo "${SHA256[$arch]}  $copy" | shasum -a 256 -c - > /dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$copy" \
      "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/cloudflared-darwin-$arch.tgz"
    echo "${SHA256[$arch]}  $copy" | shasum -a 256 -c - > /dev/null
    cp "$copy" "$tgz.part" && mv "$tgz.part" "$tgz"
  fi
  mkdir -p "$work/$arch"
  tar -xzf "$copy" -C "$work/$arch" cloudflared
}

fetch arm64
fetch amd64

mkdir -p "$(dirname "$dest")"
rm -f "$dest"
lipo -create -output "$dest" "$work/arm64/cloudflared" "$work/amd64/cloudflared"

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$dest"
