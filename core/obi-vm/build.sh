#!/bin/sh
# Builds obi-vm into $1 (default: ./build/obi-vm), signed with the virtualization entitlement:
# ad hoc here; the release signs it with Developer ID inside Oby.app (Contents/Helpers/obi-vm).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build/obi-vm}
mkdir -p "$(dirname "$out")"
xcrun swiftc -O -swift-version 5 -o "$out" "$here/main.swift"
codesign --force --sign "${OBI_VM_SIGN:--}" --options runtime --entitlements "$here/obi-vm.entitlements" "$out"
