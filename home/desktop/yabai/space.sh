#!/bin/bash
# Space navigation for skhd and SketchyBar. The daemon owns the whole
# operation, so key repeats cannot interleave global opacity configuration.
# Requires the signed fork's `space --navigate` command.
yabai="@yabai@"
fade_from=0.9
fade_duration=0.15

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

exec "$yabai" -m space --navigate "$action" "$selector" "$fade_from" "$fade_duration"
