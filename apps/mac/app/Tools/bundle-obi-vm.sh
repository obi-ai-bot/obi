#!/bin/zsh
# Bundles obi-vm, the box for a teammate's job on this Mac (#797; core/obi-vm), with Oby:
# Contents/Helpers/obi-vm, beside obid, which looks for it there. It is built for the guest image
# core/obi-vm/image.json pins (its SHA-256s baked in: it boots that image and nothing else; obid
# fetches that image when the owner turns sharing on) and signed with the app's identity, the
# hardened runtime and the virtualization entitlement, the only part of Oby that has it. Apple
# silicon only: the image is arm64. Run by the "Bundle obi-vm" build phase of the Oby target
# (apps/Oby.xcodeproj).
set -euo pipefail

root="$SRCROOT/.."
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
# Only a full build carries it (OBY_FULL_BUILD=1, docs/release.md): sharing is hidden in the launch
# build (AGENTS.md, "The launch build"). Without it, what an earlier full build left goes; obid
# then says "This Oby has no obi-vm" (core/crates/obid/src/sphere/hosting.rs).
if [[ "${OBY_FULL_BUILD:-}" != 1 ]]; then rm -f "$helpers/obi-vm"; exit 0; fi
mkdir -p "$helpers"
pin="$root/core/obi-vm/image.json"
if [[ ! -f "$pin" ]]; then
  if [[ "${CONFIGURATION:-Debug}" == Release ]]; then
    echo "error: a release of Oby needs core/obi-vm/image.json, the guest image obi-vm boots" >&2
    exit 1
  fi
  pin=""
fi

# Xcode's build variables would point swiftc at the wrong SDK, so it builds in a clean environment.
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
  OBI_VM_TARGET=arm64-apple-macos26.0 \
  /bin/sh "$root/core/obi-vm/build.sh" "$helpers/obi-vm" ${pin:+"$pin"} > /dev/null

# Signed like the app (build.sh signed it ad hoc): the hardened runtime and the entitlement, and a
# secure timestamp on release builds. Xcode seals the app, with this inside, after this phase.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp=--timestamp=none
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == Release ]]; then timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --entitlements "$root/core/obi-vm/obi-vm.entitlements" \
  --sign "$identity" "$helpers/obi-vm"
