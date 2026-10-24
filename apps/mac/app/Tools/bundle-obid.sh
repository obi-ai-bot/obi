#!/bin/zsh
# Bundles obid, Oby's engine, with Oby (the owner's decision of 2026-10-18): Contents/Helpers/obid,
# signed with the app's identity and the hardened runtime, its launch agent at
# Contents/Library/LaunchAgents/com.deskree.oby.obid.plist (apps/mac/app/LoginItem.swift registers it),
# and its plug-ins (and, in a full build, its web app) at Contents/Resources/obid, where obid finds
# them from inside the app (core/crates/obid/src/app.rs). Also keeps the Swift runner's old plist
# there, only so the app can unregister it on Macs where an older Oby registered it. Run by the
# "Bundle obid" build phase of the Oby target (apps/Oby.xcodeproj).
set -euo pipefail

root="$SRCROOT/.."
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
helpers="$contents/Helpers"
agents="$contents/Library/LaunchAgents"
resources="$contents/Resources/obid"
mkdir -p "$helpers" "$agents" "$resources"

# Xcode's build variables would point cargo at the wrong SDK, so it builds in a clean environment.
# scripts/release.sh passes OBY_CARGO_TARGET_DIR, a target directory kept between releases.
target_dir="${OBY_CARGO_TARGET_DIR:-$root/core/target}"
build=(env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  cargo build --quiet --release -p obid --manifest-path "$root/core/Cargo.toml" --target-dir "$target_dir")

# Both architectures when this Mac's Rust has both, in one cargo run so they compile side by side;
# a release needs them.
targets=()
slices=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  libdir=$(env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    rustc --print target-libdir --target "$target" 2>/dev/null || true)
  if [[ -n "$libdir" ]] && ls "$libdir"/libstd-* > /dev/null 2>&1; then
    targets+=(--target "$target")
    slices+=("$target_dir/$target/release/obid")
  fi
done
if (( ${#slices} == 0 )); then
  "${build[@]}"
  slices=("$target_dir/release/obid")
else
  "${build[@]}" "${targets[@]}"
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
# The web app obid serves at /app/, only in a full build (OBY_FULL_BUILD=1, docs/release.md; the
# launch build leaves it out, AGENTS.md, "The launch build"): a full release builds it, a full debug
# build when it isn't built yet, and either fails if it can't. Without it obid answers 404 there.
if [[ "${OBY_FULL_BUILD:-}" == 1 ]]; then
  if [[ "${CONFIGURATION:-Debug}" == Release || ! -f "$root/apps/web/dist/index.html" ]]; then
    env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      zsh -c 'cd "$1" && npm ci --silent && npm run build --silent' zsh "$root/apps/web" \
      || { echo "error: a full build of Oby needs obid's web app: npm ci && npm run build in apps/web failed" >&2; exit 1; }
  fi
  cp -R "$root/apps/web/dist" "$resources/web"
fi

# Signed like the app: the hardened runtime for notarization, and a secure timestamp on release
# builds (it needs the network). Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$helpers/obid"
