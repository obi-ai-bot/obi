#!/bin/sh
# Builds obi-vm into $1 (default: ./build/obi-vm) for the image whose image.json is $2 (its
# SHA-256s are baked in: that obi-vm boots that image and nothing else), signed with the
# virtualization entitlement: ad hoc here; the release signs it with Developer ID inside Oby.app
# (Contents/Helpers/obi-vm). Without $2 it boots nothing (`obi-vm signals` still works).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build/obi-vm}
mkdir -p "$(dirname "$out")"
# OBI_VM_DEBUG=1: the smoke test's build (smoke.sh), which may boot its own init; never released.
hashes=$(mktemp -d)/image-hashes.swift
if [ -n "${2:-}" ]; then
  jq -r '"let bakedImage: [String: String] = [\"vmlinuz\": \"\(.vmlinuz)\", \"initrd\": \"\(.initrd)\", \"root.img\": \"\(.["root.img"])\"]"' "$2" > "$hashes"
else
  echo 'let bakedImage: [String: String] = [:]' > "$hashes"
fi
xcrun swiftc -O -swift-version 5 ${OBI_VM_DEBUG:+-D OBI_VM_DEBUG} -o "$out" "$here/main.swift" "$hashes"
rm -f "$hashes"
codesign --force --sign "${OBI_VM_SIGN:--}" --options runtime --entitlements "$here/obi-vm.entitlements" "$out"
