#!/usr/bin/env bash
# Fuego Valise — Linux release installer.
#
# Installs the single "Fuego Valise" desktop entry together with its icon and
# wires the launch target into ~/.local/bin. The release tarball itself is
# intentionally flat (binary + backends + lib/ + data/ + desktop + icon); this
# script performs the user-level installation so the freedesktop menu shows
# exactly one Fuego Valise entry, with icon, instead of a raw bundle.
#
# Usage: ./install-fuego-valise.sh [source-dir]
#   source-dir defaults to the unpacked release folder (the one holding
#   "fuego-valise", the backends, lib/, data/, xfg-wallet.desktop and fuego.png).

set -euo pipefail

SRC="${1:-./fuego-valise}"
APP_ID="fuego-valise"
APP_DIR="$HOME/.local/share/$APP_ID"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor"

if [ ! -d "$SRC" ]; then
  echo "install-fuego-valise.sh: source directory not found: $SRC" >&2
  exit 1
fi

for f in fuego-valise xfg-wallet.desktop fuego.png; do
  if [ ! -e "$SRC/$f" ]; then
    echo "install-fuego-valise.sh: missing $SRC/$f" >&2
    exit 1
  fi
done

mkdir -p "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR/512x512/apps"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$SRC"/. "$APP_DIR"/

ln -sfn "$APP_DIR/fuego-valise" "$BIN_DIR/$APP_ID"

sed "s|^Exec=.*|Exec=$HOME/.local/bin/$APP_ID|" \
  "$SRC/xfg-wallet.desktop" > "$DESKTOP_DIR/$APP_ID.desktop"

cp "$SRC/fuego.png" "$ICON_DIR/512x512/apps/fuego.png"

update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

echo "Fuego Valise installed to $APP_DIR"
echo "Desktop entry: $DESKTOP_DIR/$APP_ID.desktop"
echo "Icon:          $ICON_DIR/512x512/apps/fuego.png"
echo "Launch via:    $BIN_DIR/$APP_ID"
