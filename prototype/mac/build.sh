#!/bin/zsh
# Builds Cube.app (menu bar only) into prototype/build and launches it.
set -euo pipefail
here=${0:A:h}
app="$here/../build/Cube.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/../web/index.html" "$app/Contents/Resources/web/"
swiftc -O "$here/main.swift" -o "$app/Contents/MacOS/Cube" -framework Cocoa -framework WebKit

pkill -x Cube 2>/dev/null && sleep 1 || true
open "$app"
