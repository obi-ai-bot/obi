#!/bin/zsh
# Builds the sample menu bar host, Oby.app, into mac/build and launches it.
set -euo pipefail
here=${0:A:h}
app="$here/build/Oby.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web/vendor"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/../oby.html" "$app/Contents/Resources/web/"
cp "$here/../vendor/three.module.js" "$app/Contents/Resources/web/vendor/"
swiftc -O -target arm64-apple-macos13.0 "$here/main.swift" -o "$app/Contents/MacOS/Oby" -framework Cocoa -framework WebKit

pkill -x Oby 2>/dev/null && sleep 1 || true
open "$app"
