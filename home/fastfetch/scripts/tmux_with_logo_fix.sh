#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script to display a random logo image using Kitty terminal and run Fastfetch.

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
PNG_DIR="$CONFIG_DIR/pngs"
CONFIG_FILE="$CONFIG_DIR/config.jsonc"

# Find a random image in the configured directory.
if command -v shuf >/dev/null 2>&1; then
  image=$(find "$PNG_DIR" -type f -name "*.png" | shuf -n 1)
else
  image=$(find "$PNG_DIR" -type f -name "*.png" | awk 'BEGIN { srand() } { files[NR] = $0 } END { if (NR > 0) print files[int(rand() * NR) + 1] }')
fi

# Check if an image was found.
if [[ -z "$image" ]]; then
  echo "No images found in the configured directory" >&2
  exit 1
fi

# Visualize the image with Kitty when available.
if command -v kitty >/dev/null 2>&1 \
  && [[ -t 1 ]] \
  && { [[ -n "${KITTY_WINDOW_ID:-}" ]] || [[ "${TERM:-}" == xterm-kitty* ]]; }; then
  cols=$(tput cols 2>/dev/null || echo 120)
  lines=$(tput lines 2>/dev/null || echo 40)

  image_width=30
  image_height=18

  image_x=$((cols / 2 - image_width / 2))
  image_y=$((lines / 2 - image_height / 2))

  kitty +kitten icat \
    --silent \
    --place "${image_width}x${image_height}@${image_x}x${image_y}" \
    "$image" || true
fi

# Run Fastfetch with the JSON configuration file.
fastfetch --config "$CONFIG_FILE"
