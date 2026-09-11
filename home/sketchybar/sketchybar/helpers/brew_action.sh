#!/bin/bash
# Click controller. The --run branch executes inside the terminal.
set -u

if [ "${1:-}" = --run ]; then
  shift
  brew_path=$1
  provider=$2
  action=$3
  refresh() { /usr/bin/pkill -USR1 -f "^${provider} brew_update([[:space:]]|$)" 2>/dev/null || true; }
  trap refresh EXIT
  "$brew_path" "$action"
  result=$?
  refresh
  trap - EXIT
  printf '\n'
  read -r -p 'Press Enter to close...' || true
  exit "$result"
fi

brew_path=$1
provider=$2
[ -x "$brew_path" ] || exit 1
case "${BUTTON:-left}" in
  other|middle)
    /usr/bin/pkill -USR1 -f "^${provider} brew_update([[:space:]]|$)"
    ;;
  left|right)
    action=outdated
    [ "${BUTTON:-left}" = right ] && action=upgrade
    /usr/bin/open -n -a Ghostty --args -e /bin/bash "$0" --run "$brew_path" "$provider" "$action"
    ;;
esac
