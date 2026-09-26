#!/bin/bash
# Space navigation for skhd and SketchyBar, with a short fade-in of the
# windows on a space that was not visible before the switch.
#
#   space.sh focus <index|next|prev>  focus a space and its frontmost window
#   space.sh move  <index|next|prev>  send the focused window there, follow it
#
# <index> is the mission-control index shown by SketchyBar. next and prev wrap
# around, falling back to yabai's first and last selectors at the ends.
#
# Runs under macOS's /bin/bash 3.2, so it avoids bash 4 features.

# Substituted by Home Manager with the Nix store paths of yabai and jq.
yabai="@yabai@"
jq="@jq@"

# Opacity the incoming windows start from, and how long their fade-in lasts in
# seconds. A fade_duration of 0 switches instantly.
fade_from=0.2
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

# Prints the target space as JSON; fails when it does not exist.
resolve_space() {
  case $1 in
  next)
    "$yabai" -m query --spaces --space next 2>/dev/null ||
      "$yabai" -m query --spaces --space first
    ;;
  prev)
    "$yabai" -m query --spaces --space prev 2>/dev/null ||
      "$yabai" -m query --spaces --space last
    ;;
  *) "$yabai" -m query --spaces --space "$1" 2>/dev/null ;;
  esac
}

space=$(resolve_space "$selector") || exit 0
read -r index visible focused <<<"$("$jq" -r \
  '"\(.index) \(."is-visible") \(."has-focus")"' <<<"$space")"
case $index in
'' | *[!0-9]*) exit 1 ;;
esac

# Nothing to do when the target is the focused space already: refocusing it
# would only move focus away from the window the user is on.
[ "$focused" = true ] && exit 0

window_id=""
if [ "$action" = move ]; then
  window_id=$("$yabai" -m query --windows --window 2>/dev/null |
    "$jq" -r '.id // empty')
  [ -n "$window_id" ] || exit 0
  "$yabai" -m window "$window_id" --space "$index" || exit 1
fi

# Windows come back front to back; minimized, hidden and sticky ones are not
# part of what the space shows, so they are neither faded nor focused.
windows=$("$yabai" -m query --windows --space "$index" 2>/dev/null |
  "$jq" -r '.[] | select(.role == "AXWindow")
    | select((."is-minimized" or ."is-hidden" or ."is-sticky") | not) | .id')
[ -n "$window_id" ] || window_id=${windows%%$'\n'*}

# A space shown on another display is already on screen, so fading it would
# only flash its windows.
fade_ids=""
if [ "$visible" != true ]; then
  case $fade_duration in
    0 | 0.0 | .0) ;;
    *) fade_ids=$windows ;;
  esac
fi

restore_duration=""
fade_in() {
  [ -n "$restore_duration" ] || return 0
  "$yabai" -m config window_opacity_duration "$fade_duration"
  # 0.0 hands each window back to active/normal_window_opacity.
  for id in $fade_ids; do
    "$yabai" -m window "$id" --opacity 0.0 2>/dev/null
  done
  # A running fade keeps the duration it started with.
  "$yabai" -m config window_opacity_duration "$restore_duration"
  restore_duration=""
}

if [ -n "$fade_ids" ]; then
  restore_duration=$("$yabai" -m config window_opacity_duration)
  # Undo the dimming even if the switch fails or the script is interrupted.
  trap fade_in EXIT
  trap 'exit 130' INT TERM HUP
  "$yabai" -m config window_opacity_duration 0.0
  for id in $fade_ids; do
    "$yabai" -m window "$id" --opacity "$fade_from" 2>/dev/null
  done
fi

"$yabai" -m space --focus "$index" || exit 1
fade_in

# yabai does not focus a window after a scripting-addition switch, which
# would leave keyboard focus behind on the previous space.
if [ -n "$window_id" ]; then
  "$yabai" -m window --focus "$window_id" 2>/dev/null
fi

exit 0
