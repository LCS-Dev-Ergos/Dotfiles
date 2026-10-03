#!/bin/bash
# Desktop navigation effect controls for skhd and SketchyBar. space.sh sends
# no effect, so the daemon's settings choose it; this script changes them
# while yabai runs:
#   toggle  switch the effects on or off (navigation_effect)
#   type    swap the crossfade and the veil (navigation_effect_type)
#   curve   swap the crossfade's fade curve, smooth or ease_out
#           (navigation_fade_curve); nothing while the veil is chosen
#   status  print "<on|off> <crossfade|veil> <smooth|ease_out>"
#   announce  tell SketchyBar the current settings
# yabai keeps them until it exits; yabairc sets them again at its start. Every
# change is announced to SketchyBar's navigation_effect_changed event with
# EFFECT, TYPE and CURVE, or shown as a notification when no bar runs.
yabai_msg="@yabai_msg@"

usage() {
  printf 'usage: %s {toggle|type|curve|status|announce}\n' "${0##*/}" >&2
  exit 64
}

[ $# -eq 1 ] || usage
case $1 in
toggle | type | curve | status | announce) ;;
*) usage ;;
esac

get() {
  "$yabai_msg" config "$1"
}

set_value() {
  "$yabai_msg" config "$1" "$2"
}

# Reads the three settings into effect, type and curve. Fails when yabai does
# not answer or answers with a value this script does not know.
read_settings() {
  effect=$(get navigation_effect) &&
    type=$(get navigation_effect_type) &&
    curve=$(get navigation_fade_curve) || return 1

  case $effect in on | off) ;; *) return 1 ;; esac
  case $type in crossfade | veil) ;; *) return 1 ;; esac
  case $curve in smooth | ease_out) ;; *) return 1 ;; esac
}

# The bar's path differs between Home Manager and Homebrew, and skhd's PATH
# may not hold either.
sketchybar_path() {
  local candidate
  for candidate in "$(command -v sketchybar 2>/dev/null)" \
    "/etc/profiles/per-user/$USER/bin/sketchybar" \
    "$HOME/.nix-profile/bin/sketchybar" \
    /opt/homebrew/bin/sketchybar; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done
  return 1
}

announce() {
  local bar
  if bar=$(sketchybar_path) &&
    "$bar" --trigger navigation_effect_changed \
      "EFFECT=$effect" "TYPE=$type" "CURVE=$curve" >/dev/null 2>&1; then
    return 0
  fi

  # The values are checked words, so they are safe inside the script text.
  local text
  if [ "$effect" = off ]; then
    text='Effects off'
  elif [ "$type" = veil ]; then
    text='Veil'
  else
    text="Crossfade, $curve"
  fi
  /usr/bin/osascript -e "display notification \"$text\" with title \"Desktop navigation\"" >/dev/null 2>&1
  return 0
}

read_settings || {
  printf '%s: yabai did not report its navigation settings\n' "${0##*/}" >&2
  exit 1
}

case $1 in
toggle)
  if [ "$effect" = on ]; then effect=off; else effect=on; fi
  set_value navigation_effect "$effect" || exit 1
  ;;
type)
  if [ "$type" = crossfade ]; then type=veil; else type=crossfade; fi
  set_value navigation_effect_type "$type" || exit 1
  ;;
curve)
  # The curve is the crossfade's transition; the veil keeps it as it is.
  if [ "$type" = crossfade ]; then
    if [ "$curve" = smooth ]; then curve=ease_out; else curve=smooth; fi
    set_value navigation_fade_curve "$curve" || exit 1
  fi
  ;;
status)
  printf '%s %s %s\n' "$effect" "$type" "$curve"
  exit 0
  ;;
announce) ;;
esac

announce
