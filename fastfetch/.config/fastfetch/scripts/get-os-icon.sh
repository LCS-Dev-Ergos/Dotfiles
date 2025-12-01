#!/bin/sh
# Returns just the icon for the current OS

case $(uname -s) in
  Darwin)
    echo ' 󰀵 '
    ;;
  Linux)
    if [ -f /etc/os-release ]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      case $ID in
        arch | archlinux) echo ' 󰣇 ' ;;
        ubuntu) echo '  ' ;;
        debian) echo '  ' ;;
        fedora) echo '  ' ;;
        centos) echo '  ' ;;
        gentoo) echo '  ' ;;
        nixos) echo '  ' ;;
        *) echo '  ' ;;
      esac
    else
      echo '  '
    fi
    ;;
  *BSD)
    echo '  '
    ;;
  *)
    echo '  '
    ;;
esac
