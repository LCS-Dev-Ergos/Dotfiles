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
    # AppKit can treat positional -e arguments as files to open, prompting for
    # execution and creating extra surfaces. Keep the command in one option.
    quote() {
      local value=$1 escaped_quote="'\\''"
      value=${value//\'/$escaped_quote}
      printf "'%s'" "$value"
    }
    command="/bin/bash $(quote "$0") --run $(quote "$brew_path") $(quote "$provider") $(quote "$action")"
    /usr/bin/open -n -a Ghostty --args \
      --window-save-state=never --quit-after-last-window-closed=true \
      "--initial-command=$command"
    ;;
esac
