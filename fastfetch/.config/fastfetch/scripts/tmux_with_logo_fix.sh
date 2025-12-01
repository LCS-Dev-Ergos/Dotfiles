#!/bin/bash

# Find a random image in the configured directory
image=$(find "${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch/pngs/" -name "*.png" | shuf -n 1)

# Check if an image was found
if [[ -z "$image" ]]; then
  echo "No images found in the configured directory" >&2
  exit 1
fi

# Calculating dimensions and positioning
# Use specific values for height/width
cols=$(tput cols)
lines=$(tput lines)

image_width=30
image_height=18

image_x=$((cols / 2 - 15))
image_y=$((lines / 2 - 9))

# Visualize the image with Kitty
kitty +kitten icat \
  --silent \
  --place "${image_width}x${image_height}@${image_x}x${image_y}" \
  "$image"

# Use Kitty to display the image
kitty +kitten icat --align left --silent "$image"

# Run Fastfetch with the JSON configuration file
fastfetch --config "$HOME/.config/fastfetch/config.jsonc"
