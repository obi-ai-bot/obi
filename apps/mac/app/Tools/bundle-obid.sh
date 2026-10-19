#!/bin/zsh
# Bundles obid, Oby's engine, with Oby (the owner's decision of 2026-10-18): Contents/Helpers/obid,
# signed with the app's identity and the hardened runtime, its launch agent at
# Contents/Library/LaunchAgents/com.deskree.oby.obid.plist (apps/mac/app/LoginItem.swift registers it),
# and its plug-ins and web app at Contents/Resources/obid, where obid finds them from inside the
# app (core/crates/obid/src/app.rs). Also keeps the Swift runner's old plist there, only so the app
# can unregister it on Macs where an older Oby registered it. Run by the "Bundle obid" build phase
# of the Oby target (apps/Oby.xcodeproj).
set -euo pipefail

root="$SRCROOT/.."
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
helpers="$contents/Helpers"
agents="$contents/Library/LaunchAgents"
resources="$contents/Resources/obid"
mkdir -p "$helpers" "$agents" "$resources"

# Xcode's build variables would point cargo at the wrong SDK, so it builds in a clean environment.
build=(env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  cargo build --quiet --release -p obid --manifest-path "$root/core/Cargo.toml")

# Both architectures when this Mac's Rust has both; a release needs them.
slices=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  libdir=$(env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    rustc --print target-libdir --target "$target" 2>/dev/null || true)
  if [[ -n "$libdir" ]] && ls "$libdir"/libstd-* > /dev/null 2>&1; then
    "${build[@]}" --target "$target"
    slices+=("$root/core/target/$target/release/obid")
  fi
done
if (( ${#slices} == 0 )); then
  "${build[@]}"
  slices=("$root/core/target/release/obid")
fi
if [[ "${CONFIGURATION:-Debug}" == Release ]] && (( ${#slices} < 2 )); then
  echo "error: a release of Oby needs obid for arm64 and x86_64: rustup target add aarch64-apple-darwin x86_64-apple-darwin" >&2
  exit 1
fi
rm -f "$helpers/obid"
lipo -create -output "$helpers/obid" "${slices[@]}"
chmod 755 "$helpers/obid"

cp "$SRCROOT/mac/app/Tools/com.deskree.oby.obid.plist" "$agents/com.deskree.oby.obid.plist"
cp "$root/Runner/com.deskree.oby.runner.plist" "$agents/com.deskree.oby.runner.plist"

rm -rf "$resources/plugins" "$resources/web"
# Only the plug-ins' files the repository tracks: nothing a checkout happens to hold (a local
# secret, a build folder) is signed into the app.
git -C "$root" ls-files -z -- plugins | rsync -a --from0 --files-from=- "$root/" "$resources/"
# The web app obid serves at /app/: a release builds it, and fails if it can't; a debug build takes
# it when it's built, and obid answers 404 there otherwise.
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then
  env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    zsh -c 'cd "$1" && npm ci --silent && npm run build --silent' zsh "$root/apps/web" \
    || { echo "error: a release of Oby needs obid's web app: npm ci && npm run build in apps/web failed" >&2; exit 1; }
fi
if [[ -f "$root/apps/web/dist/index.html" ]]; then cp -R "$root/apps/web/dist" "$resources/web"; fi

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$helpers/obid"
