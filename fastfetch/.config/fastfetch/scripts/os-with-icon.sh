#!/bin/sh
# Get OS info without recursive fastfetch call

case $(uname -s) in
  Darwin)
    # macOS
    if command -v sw_vers >/dev/null 2>&1; then
      VERSION=$(sw_vers -productVersion)
      BUILD=$(sw_vers -buildVersion)
      ARCH=$(uname -m)
      echo "macOS $VERSION ($BUILD) $ARCH"
    else
      echo "$(uname -s) $(uname -r) $(uname -m)"
    fi
    ;;
  Linux)
    if [ -f /etc/os-release ]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      echo "$PRETTY_NAME"
    else
      echo "$(uname -s) $(uname -r) $(uname -m)"
    fi
    ;;
  *BSD)
    echo "$(uname -s) $(uname -r) $(uname -m)"
    ;;
  *)
    echo "$(uname -s) $(uname -r) $(uname -m)"
    ;;
esac
