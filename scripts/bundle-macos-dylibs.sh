#!/bin/bash

# Bundle macOS daemon dependencies into the app.
#
# The fuego-suite C++ daemons (fuegod, unified, xfg-swapd) link against homebrew
# dylibs at absolute paths (/opt/homebrew/opt/...). End users do not have
# those paths — without this step every C++ daemon dies with "Library not
# loaded" on a clean machine.
#
# Usage: bundle-macos-dylibs.sh <app_bundle_dir>
#
# Relocates all homebrew dylib references into Contents/Frameworks and
# re-signs everything (install_name_tool invalidates signatures).
#
# Failure handling: a dylib referenced by a daemon may not exist on the
# bundling machine (homebrew boost 1.90+ dropped libboost_system.dylib,
# header-only since Boost 1.69) and a bundled dylib may have no homebrew
# references at all (some ICU install names are bare file names). Both
# cases used to kill the script mid-bundle via `set -e`/`pipefail` — the
# former with a cryptic `cp` error, the latter with no error at all.
# Instead, bundling continues, and a final verification pass fails with
# the exact list of unresolved /opt/homebrew load commands, so a broken
# bundle is never produced silently.

set -euo pipefail

APP="${1:?usage: bundle-macos-dylibs.sh <app_bundle_dir>}"
BIN_DIR="$APP/Contents/MacOS"
FW_DIR="$APP/Contents/Frameworks"
mkdir -p "$FW_DIR"

DAEMONS=("$BIN_DIR/fuegod" "$BIN_DIR/unified" "$BIN_DIR/xfg-swapd")

# otool -L can contain no /opt/homebrew paths (no-match grep exits 1).
# Under `set -o pipefail` that kills the script; `|| true` keeps going.
homebrew_refs() {
    otool -L "$1" | grep -o '/opt/homebrew/[^ ]*\.dylib' | sort -u || true
}

for bin in "${DAEMONS[@]}"; do
    [ -f "$bin" ] || continue

    # 1. Copy every homebrew dylib the daemon references and rewrite the
    #    load command to the bundle-relative path. A referenced dylib that
    #    no longer exists in homebrew is left in place — the final
    #    verification pass reports it instead of aborting mid-bundle.
    while read -r dylib; do
        name="$(basename "$dylib")"
        if [ ! -f "$FW_DIR/$name" ]; then
            if ! cp "$dylib" "$FW_DIR/" 2>/dev/null; then
                echo "warning: cannot copy $dylib (not installed in homebrew); its load command stays untouched" >&2
                continue
            fi
        fi
        install_name_tool -change "$dylib" "@executable_path/../Frameworks/$name" "$bin"
    done < <(homebrew_refs "$bin")

    # 2. Re-sign the daemon (step 1 invalidated its signature).
    codesign --force --sign - "$bin" >/dev/null 2>&1 || true
done

# 3. Fix dylib-internal references (boost libs reference each other,
#    openssl/icu reference nothing homebrew) and re-sign each dylib.
for dylib in "$FW_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    while read -r ref; do
        install_name_tool -change "$ref" "@loader_path/$(basename "$ref")" "$dylib"
    done < <(homebrew_refs "$dylib")
    install_name_tool -id "@loader_path/$(basename "$dylib")" "$dylib"
    codesign --force --sign - "$dylib" >/dev/null 2>&1 || true
done

# 4. Verification: no daemon or bundled dylib may still reference an
#    absolute homebrew path. Fail with the exact list if any remain.
RESOLVE_FAILED=0
check_bundle_clean() {
    local file="$1"
    local refs
    refs="$(homebrew_refs "$file")"
    if [ -n "$refs" ]; then
        echo "error: $file still references homebrew dylibs:" >&2
        echo "$refs" | sed 's/^/  /' >&2
        RESOLVE_FAILED=1
    fi
}
for bin in "${DAEMONS[@]}"; do
    [ -f "$bin" ] && check_bundle_clean "$bin"
done
for dylib in "$FW_DIR"/*.dylib; do
    [ -f "$dylib" ] && check_bundle_clean "$dylib"
done

if [ "$RESOLVE_FAILED" -ne 0 ]; then
    echo "error: bundle incomplete — rebuild the daemons against the same homebrew packages used for bundling (fuego-suite needs boost 1.90+, openssl@3, icu4c, jsoncpp)." >&2
    exit 1
fi

echo "Bundled $(ls "$FW_DIR" | wc -l | tr -d ' ') dylibs into $FW_DIR"
