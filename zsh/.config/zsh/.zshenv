#!/usr/bin/env zsh

#! ██████╗░░█████╗░  ███╗░░██╗░█████╗░████████╗  ███████╗██████╗░██╗████████╗
#! ██╔══██╗██╔══██╗  ████╗░██║██╔══██╗╚══██╔══╝  ██╔════╝██╔══██╗██║╚══██╔══╝
#! ██║░░██║██║░░██║  ██╔██╗██║██║░░██║░░░██║░░░  █████╗░░██║░░██║██║░░░██║░░░
#! ██║░░██║██║░░██║  ██║╚████║██║░░██║░░░██║░░░  ██╔══╝░░██║░░██║██║░░░██║░░░
#! ██████╔╝╚█████╔╝  ██║░╚███║╚█████╔╝░░░██║░░░  ███████╗██████╔╝██║░░░██║░░░
#! ╚═════╝░░╚════╝░  ╚═╝░░╚══╝░╚════╝░░░░╚═╝░░░  ╚══════╝╚═════╝░╚═╝░░░╚═╝░░░

# Load all custom module files // Directories are ignored
# As Directories are ignored, we can store a bunch of boilerplate script in a ``./conf.d/custom-directory``
# then we can make an entry point script: `./conf.d/custom-directory.zsh`managing all the files in that directory

# Platform detection - only load HyDE configuration on Arch Linux
# On macOS, skip HyDE and use the custom lib/ configuration instead
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  if [[ "$ID" == "arch" ]]; then
    for file in "${ZDOTDIR:-$HOME/.config/zsh}/conf.d/"*.zsh; do
      [ -r "$file" ] && source "$file"
    done
  fi
fi
