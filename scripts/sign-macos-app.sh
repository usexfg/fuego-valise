#!/bin/bash
# Signs bundled executables, Frameworks, then the app. Identity "-" signs ad-hoc.
set -euo pipefail

APP="${1:?usage: sign-macos-app.sh <app_bundle> <identity>}"
IDENTITY="${2:?usage: sign-macos-app.sh <app_bundle> <identity>}"

opts=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
    opts+=(--options runtime --timestamp)
fi

for b in fuego_walletd fuegod xfg-swapd unified; do
    if [ -f "$APP/Contents/MacOS/$b" ]; then codesign "${opts[@]}" "$APP/Contents/MacOS/$b"; fi
done
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name "*.dylib" -o -name "*.framework" \) -print0 |
    while IFS= read -r -d '' f; do codesign "${opts[@]}" "$f"; done
codesign "${opts[@]}" "$APP"
codesign --verify --deep --strict "$APP"
