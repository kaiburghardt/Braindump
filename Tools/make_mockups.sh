#!/bin/zsh
# Puts the raw README window captures on a MacBook (Tools/make_mockup.swift) and writes
# docs/screenshot-dark.png and docs/screenshot-light.png (1800 px wide, transparent background).
# Usage: Tools/make_mockups.sh <dark-window.png> <light-window.png>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <dark-window.png> <light-window.png>"; exit 1; }
DARK="${1:A}"
LIGHT="${2:A}"
cd "${0:A:h}/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O Tools/make_mockup.swift -o "$TMP/make_mockup"
"$TMP/make_mockup" "$DARK" "$TMP/dark.png" dark 1800
"$TMP/make_mockup" "$LIGHT" "$TMP/light.png" light 1800
mv "$TMP/dark.png" docs/screenshot-dark.png
mv "$TMP/light.png" docs/screenshot-light.png
echo "✓ docs/screenshot-dark.png, docs/screenshot-light.png"
