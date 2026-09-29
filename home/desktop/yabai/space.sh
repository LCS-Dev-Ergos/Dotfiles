#!/bin/bash
# Space navigation for skhd and SketchyBar. The daemon owns the whole
# operation, so key repeats cannot interleave global opacity configuration.
# Requires the signed fork's `space --navigate` command.
yabai="@yabai@"
# The whole display crossfades to the Desktop that was hidden in
# effect_duration seconds. `crossfade` can be replaced with a starting opacity
# in (0,1] to fade in only the destination's windows instead, over the
# wallpaper; a duration of 0 switches without an effect.
effect=crossfade
effect_duration=0.25

usage() {
  printf 'usage: %s {focus|move} <index|next|prev>\n' "${0##*/}" >&2
  exit 64
}

[ $# -eq 2 ] || usage
action=$1
selector=$2
case $action in
focus | move) ;;
*) usage ;;
esac
case $selector in
next | prev) ;;
'' | *[!0-9]*) usage ;;
esac

exec "$yabai" -m space --navigate "$action" "$selector" "$effect" "$effect_duration"
