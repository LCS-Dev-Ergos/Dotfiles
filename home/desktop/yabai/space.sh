#!/bin/bash
# Space navigation for skhd and SketchyBar. The daemon owns the whole
# operation, so key repeats cannot interleave global opacity configuration.
# Requires yabai 8.0.0 or later, whose `space --navigate` may name no effect.
yabai_msg="@yabai_msg@"
# The request names no effect, so the daemon's settings choose it: yabairc
# sets them at yabai's start and navfx.sh changes them while it runs, so this
# script stays the same. A request can still name its own, as in
#   "$yabai_msg" space --navigate focus next veil 0.25
# with `crossfade`, `veil` or a starting opacity in (0,1] for a fade of the
# destination's windows, and a duration in [0,1] seconds.

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

exec "$yabai_msg" space --navigate "$action" "$selector"
