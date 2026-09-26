#!/bin/bash
# Checks that the fuego-ffi exports Dart resolves via DynamicLibrary.process() are
# global symbols in an iOS Runner binary, an .xcarchive or an .ipa. Stripping at
# archive or export time removes them, and the app then fails at the first FFI call.
#
# Usage: check-ios-ffi-symbols.sh <Runner binary | Runner.xcarchive | App.ipa>
set -euo pipefail

target="${1:?usage: check-ios-ffi-symbols.sh <Runner | .xcarchive | .ipa>}"
tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT

case "$target" in
  *.ipa)
    tmp=$(mktemp -d)
    unzip -q "$target" 'Payload/*.app/Runner' -d "$tmp"
    bin=$(ls "$tmp"/Payload/*.app/Runner)
    ;;
  *.xcarchive) bin="$target/Products/Applications/Runner.app/Runner" ;;
  *) bin="$target" ;;
esac

syms=$(nm -gU "$bin")
missing=0
for s in fuego_string_free fuego_bytes_free fuego_vault_from_seed fuego_vault_get_address \
         fuego_make_address fuego_mine_share fuego_cn_slow_hash; do
  if ! grep -q " _$s\$" <<<"$syms"; then
    echo "missing _$s in $bin"
    missing=1
  fi
done
[ "$missing" -eq 0 ] && echo "fuego-ffi symbols present: $bin"
exit "$missing"
