#!/bin/zsh
# Bundles GitHub's CLI with Oby (the owner's decision of 2026-10-18, docs/onboarding.md §8):
# Contents/MacOS/gh, universal, signed with the app's identity and the hardened runtime, so it's
# notarized with the app and nobody installs gh to use Oby. obid finds it beside its own executable
# (core/crates/obid/src/github.rs, gh). gh keeps its own login in its own Keychain item; Oby never
# reads it. The release is pinned and checked against its SHA-256; the download is cached under
# ~/Library/Caches, never in the repository. Run by the "Bundle gh" build phase of the Oby target
# (apps/Oby.xcodeproj), as bundle-cloudflared.sh is.
set -euo pipefail

VERSION=2.102.0
typeset -A SHA256
SHA256[arm64]=da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e
SHA256[amd64]=b245f24eb2bf5f75b426b4c26da3651a107f8d5b6f4fddfbfccc5679041378b3
cache="${GH_BUNDLE_CACHE:-$HOME/Library/Caches/com.deskree.oby/gh}/$VERSION"

# The release's binary for one architecture, downloaded once and checked.
fetch() {
  local arch=$1 out="$cache/gh-$1"
  [[ -x "$out" ]] && return
  mkdir -p "$cache"
  local tmp name="gh_${VERSION}_macOS_$1"
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "$tmp/gh.zip" \
    "https://github.com/cli/cli/releases/download/v$VERSION/$name.zip"
  echo "${SHA256[$arch]}  $tmp/gh.zip" | shasum -a 256 -c - > /dev/null
  unzip -q "$tmp/gh.zip" "$name/bin/gh" -d "$tmp"
  chmod 755 "$tmp/$name/bin/gh"
  mv "$tmp/$name/bin/gh" "$out"
  rm -rf "$tmp"
}

fetch arm64
fetch amd64

dest="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/gh"
mkdir -p "$(dirname "$dest")"
rm -f "$dest"
lipo -create -output "$dest" "$cache/gh-arm64" "$cache/gh-amd64"

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$dest"
