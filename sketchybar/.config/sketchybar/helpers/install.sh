#!/usr/bin/env bash
set -euo pipefail

BREW="${BREW:-}"
if [ -z "$BREW" ]; then
  BREW="$(command -v brew || true)"
fi
if [ -z "$BREW" ]; then
  echo "Homebrew is required but was not found in PATH." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Packages
"$BREW" install lua
"$BREW" install switchaudio-osx
"$BREW" install nowplaying-cli

"$BREW" tap FelixKratz/formulae
"$BREW" install sketchybar

# Fonts
"$BREW" install --cask sf-symbols
"$BREW" install --cask homebrew/cask-fonts/font-sf-mono
"$BREW" install --cask homebrew/cask-fonts/font-sf-pro

font_url="https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.5/sketchybar-app-font.ttf"
font_sha256="9df255202a5ac354358c285cddf798dfdbe3b52fdf2c9dc52951aa38a872cf00"
font_dest="$HOME/Library/Fonts/sketchybar-app-font.ttf"
font_tmp="$tmpdir/sketchybar-app-font.ttf"

mkdir -p "$(dirname "$font_dest")"
curl -fL "$font_url" -o "$font_tmp"
actual_sha256="$(shasum -a 256 "$font_tmp" | awk '{print $1}')"
if [ "$actual_sha256" != "$font_sha256" ]; then
  echo "Checksum mismatch for sketchybar-app-font.ttf" >&2
  echo "expected: $font_sha256" >&2
  echo "actual:   $actual_sha256" >&2
  exit 1
fi
install -m 0644 "$font_tmp" "$font_dest"

# SbarLua
sbarlua_ref="dba9cc421b868c918d5c23c408544a28aadf2f2f"
sbarlua_dir="$tmpdir/SbarLua"
git init "$sbarlua_dir"
git -C "$sbarlua_dir" remote add origin https://github.com/FelixKratz/SbarLua.git
git -C "$sbarlua_dir" fetch --depth 1 origin "$sbarlua_ref"
git -C "$sbarlua_dir" checkout --detach FETCH_HEAD
make -C "$sbarlua_dir" install
