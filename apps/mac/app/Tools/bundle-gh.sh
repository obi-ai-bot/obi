#!/bin/zsh
# Bundles GitHub's CLI with Oby (the owner's decision of 2026-10-18, docs/onboarding.md §8):
# Contents/MacOS/gh, universal, signed with the app's identity and the hardened runtime, so it's
# notarized with the app and nobody installs gh to use Oby. obid finds it beside its own executable
# (core/crates/obid/src/github.rs, gh). gh keeps its own login in its own Keychain item; Oby never
# reads it. The release is pinned and checked against its SHA-256 on every build; the download is
# cached under ~/Library/Caches, never in the repository. Run by the "Bundle gh" build phase of the Oby target
# (apps/Oby.xcodeproj), as bundle-cloudflared.sh is.
set -euo pipefail

VERSION=2.102.0
typeset -A SHA256
SHA256[arm64]=da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e
SHA256[amd64]=b245f24eb2bf5f75b426b4c26da3651a107f8d5b6f4fddfbfccc5679041378b3
cache="${GH_BUNDLE_CACHE:-$HOME/Library/Caches/com.deskree.oby/gh}/$VERSION"

# The release's zip for one architecture: downloaded once into the cache, but the cache is the
# user's to write, so every build copies it into a private folder and checks that copy against
# its pinned SHA-256 before gh is taken out of it (a swapped file is never signed into the app).
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() {
  local arch=$1 name="gh_${VERSION}_macOS_$1"
  local zip="$cache/$name.zip" copy="$work/$name.zip"
  mkdir -p "$cache"
  if [[ -f "$zip" ]]; then cp "$zip" "$copy"; fi
  if ! echo "${SHA256[$arch]}  $copy" | shasum -a 256 -c - > /dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$copy" "https://github.com/cli/cli/releases/download/v$VERSION/$name.zip"
    echo "${SHA256[$arch]}  $copy" | shasum -a 256 -c - > /dev/null
    cp "$copy" "$zip.part" && mv "$zip.part" "$zip"
  fi
  unzip -q "$copy" "$name/bin/gh" -d "$work"
  mv "$work/$name/bin/gh" "$work/gh-$arch"
}

fetch arm64
fetch amd64

dest="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/gh"
mkdir -p "$(dirname "$dest")"
rm -f "$dest"
lipo -create -output "$dest" "$work/gh-arm64" "$work/gh-amd64"

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$dest"
