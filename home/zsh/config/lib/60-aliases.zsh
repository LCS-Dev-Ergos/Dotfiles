#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#              █████╗ ██╗     ██╗ █████╗ ███████╗███████╗███████╗
#             ██╔══██╗██║     ██║██╔══██╗██╔════╝██╔════╝██╔════╝
#             ███████║██║     ██║███████║███████╗█████╗  ███████╗
#             ██╔══██║██║     ██║██╔══██║╚════██║██╔══╝  ╚════██║
#             ██║  ██║███████╗██║██║  ██║███████║███████╗███████║
#             ╚═╝  ╚═╝╚══════╝╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
# ============================================================================ #
# +++++++++++++++++++++++++++++++++ ALIASES ++++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Cross-platform aliases and utility functions organized by category:
#   - Navigation and file operations.
#   - Development tools.
#   - Compilation shortcuts (C/C++).
#   - Git workflow.
#   - Productivity tools.
#   - Platform-specific utilities.
#
# Platform detection via $PLATFORM variable from 00-initialization.zsh
#
# ============================================================================ #

# +++++++++++++++++++++++ NAVIGATION & FILE OPERATIONS +++++++++++++++++++++++ #

# ------ Common Aliases (Cross-Platform) ------- #
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

alias rm="rm -i"
alias cp="cp -i"
alias mv="mv -i"

# -----------------------------------------------------------------------------
# cdf
# -----------------------------------------------------------------------------
# @description Selects a file with fzf and enters its containing directory.
# @noargs
# @exitcode 1 If fzf is unavailable or selection is cancelled.
# -----------------------------------------------------------------------------
cdf() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_YELLOW}fzf is required for cdf${C_RESET}" >&2
    return 1
  fi
  local target
  target=$(fzf --select-1 --exit-0)
  [[ -z "$target" ]] && return 1
  cd -- "$(dirname -- "$target")"
}

# ++++++++++++++++++++++++++++ DEVELOPMENT TOOLS +++++++++++++++++++++++++++++ #

alias ranger="TERM=screen-256color ranger"
alias clang-format="clang-format -style=file:\$CLANG_FORMAT_CONFIG"

# Redis startup (platform-aware).
if [[ "$PLATFORM" == 'macOS' ]] && [[ -x "/opt/homebrew/opt/redis/bin/redis-server" ]]; then
  alias redis-start="/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf"
elif command -v redis-server >/dev/null 2>&1; then
  alias redis-start="redis-server"
fi

# Implemented in functions/development-tools.zsh.
alias fnm-clean='fnm_clean'

# ++++++++++++++++++++++++++++ C/C++ COMPILATION +++++++++++++++++++++++++++++ #

# ---------- C Include Path ---------- #
# Determine include path dynamically based on platform.
if [[ "$PLATFORM" == 'macOS' ]] && [[ -d "/opt/homebrew/include" ]]; then
  _CC_INCLUDE_FLAG="-I/opt/homebrew/include"
elif [[ -d "/usr/local/include" ]]; then
  _CC_INCLUDE_FLAG="-I/usr/local/include"
else
  _CC_INCLUDE_FLAG=""
fi

# Toolchain Information Alias.
alias toolchain='ZSH_HIGHLIGHT_MAXLENGTH=0 get_toolchain_info 2> >(grep -v "^[a-z_]*=")'

# Default C Compilation Alias.
alias c-compile="clang -std=c23 -O3 -march=native -flto=thin -ffast-math $_CC_INCLUDE_FLAG"

# GCC C Compilation.
alias gcc-c-compile="gcc -std=c23 -O3 -march=native -flto -ffast-math $_CC_INCLUDE_FLAG"
alias gcc-c-debug="gcc -std=c23 -g -O0 -Wall -Wextra -DDEBUG $_CC_INCLUDE_FLAG"

# Clang C Compilation.
alias clang-c-compile="clang -std=c23 -O3 -march=native -flto=thin -ffast-math $_CC_INCLUDE_FLAG"
alias clang-c-debug="clang -std=c23 -g -O0 -Wall -Wextra -DDEBUG $_CC_INCLUDE_FLAG"

# Ultra Performance Clang C with ThinLTO and PGO.
alias clang-c-ultra="clang -std=c23 -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-generate=default.profraw -funroll-loops -fvectorize \
    $_CC_INCLUDE_FLAG"
alias clang-c-ultra-use="clang -std=c23 -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-use=default.profdata -funroll-loops -fvectorize \
    $_CC_INCLUDE_FLAG"

# Quick C compilation aliases.
alias qc-compile="clang -std=c23 -O2 $_CC_INCLUDE_FLAG"
alias qc-debug="clang -std=c23 -g -O0 -Wall $_CC_INCLUDE_FLAG"

# --------- C++ Compilation ---------- #
# Determine LLVM library path dynamically.
if [[ "$PLATFORM" == 'macOS' ]]; then
  if [[ -d "/opt/homebrew/opt/llvm/lib/c++" ]]; then
    _LLVM_PREFIX="/opt/homebrew/opt/llvm"
  elif [[ -d "/usr/local/opt/llvm/lib/c++" ]]; then
    _LLVM_PREFIX="/usr/local/opt/llvm"
  fi
  if [[ -n "${_LLVM_PREFIX:-}" && -d "$_LLVM_PREFIX/lib/c++" ]]; then
    _CPP_LIB_FLAGS="-L$_LLVM_PREFIX/lib/c++ -lc++"
  else
    _CPP_LIB_FLAGS="-lc++"
  fi
else
  _CPP_LIB_FLAGS="-lc++"
fi

# Default C++ Compilation Alias.
alias compile="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS \
    -O3 -march=native -flto=thin -ffast-math $_CC_INCLUDE_FLAG"

# GCC Compilation.
alias gcc-compile="g++ -std=c++23 -O3 -march=native -flto -ffast-math $_CC_INCLUDE_FLAG"
alias gcc-debug="g++ -std=c++23 -g -O0 -Wall -Wextra -DDEBUG $_CC_INCLUDE_FLAG"

# Clang Compilation.
alias clang-compile="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS \
    -O3 -march=native -flto=thin -ffast-math $_CC_INCLUDE_FLAG"
alias clang-debug="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS \
    -g -O0 -Wall -Wextra -DDEBUG $_CC_INCLUDE_FLAG"

# Ultra Performance Clang with ThinLTO and PGO.
alias clang-ultra="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-generate=default.profraw -funroll-loops -fvectorize \
    $_CC_INCLUDE_FLAG"
alias clang-ultra-use="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-use=default.profdata -funroll-loops -fvectorize \
    $_CC_INCLUDE_FLAG"

# Quick compilation aliases.
alias qcompile="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS -O2 $_CC_INCLUDE_FLAG"
alias qdebug="clang++ -std=c++23 -stdlib=libc++ $_CPP_LIB_FLAGS -g -O0 -Wall $_CC_INCLUDE_FLAG"

# +++++++++++++++++++++++++++++++ GIT WORKFLOW +++++++++++++++++++++++++++++++ #

alias gst="git status"
alias gaa="git add ."
alias gcm="git commit -m"
alias gp="git push"
alias gl="git log --oneline -10"
alias gd="git diff"
alias gb="git branch"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gpl="git pull"
alias gf="git fetch"
alias greset="git reset --hard HEAD"
alias gclean="git clean -fd"

# ++++++++++++++++++++++++++++ PRODUCTIVITY TOOLS ++++++++++++++++++++++++++++ #

alias c="clear"
alias md="mkdir -p"
alias size="du -sh"
alias size-all="du -sh .[^.]* * 2>/dev/null"
alias biggest="du -hs * | sort -hr | head -10"
# Note: epoch function moved to functions/core.zsh
alias ping="ping -c 5"
alias reload="source ~/.zshrc"
alias edit="$EDITOR ~/.zshrc"
alias zshfix="zshcache --rebuild"
alias fastfetch='~/.config/fastfetch/scripts/fastfetch-dynamic.sh'

# Note: eza/bat/duf aliases moved to functions/aliases.zsh

# ++++++++++++++++++++++++++++++ kitty Terminal ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# kreload
# -----------------------------------------------------------------------------
# @description Reloads Kitty configuration without restarting the terminal.
# @noargs
# @exitcode 1 If not running in Kitty or reload fails.
# -----------------------------------------------------------------------------
kreload() {
  if [[ -z "$KITTY_PID" ]]; then
    echo "${C_RED}Error: Not running in Kitty terminal${C_RESET}" >&2
    return 1
  fi

  if kill -SIGUSR1 "$KITTY_PID" 2>/dev/null; then
    echo "${C_GREEN}Kitty configuration reloaded${C_RESET}"
    return 0
  else
    echo "${C_RED}Error: Failed to reload Kitty configuration${C_RESET}" >&2
    return 1
  fi
}

alias kedit='$EDITOR ~/.config/kitty/kitty.conf'

# -----------------------------------------------------------------------------
# stitle
# -----------------------------------------------------------------------------
# @description Sets the terminal window or tab title.
# @arg $@ string Title text.
# -----------------------------------------------------------------------------
function stitle() {
  print -Pn "\e]2;${(V)*}\a"
}

# +++++++++++++++++++++++++++ THEFUCK INTEGRATION ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# fuck
# -----------------------------------------------------------------------------
# @description Lazily initializes thefuck and retries the current correction.
# @arg $@ string Arguments forwarded to the thefuck alias.
# Available only when thefuck is installed.
# @exitcode 1 If the alias cannot be initialized.
# -----------------------------------------------------------------------------
if command -v thefuck >/dev/null 2>&1; then
  # Lazy load thefuck to save startup time.
  fuck() {
    unfunction fuck 2>/dev/null
    eval "$(thefuck --alias 2>/dev/null)"

    # The alias is now defined, invoke it exactly once.
    if alias fuck >/dev/null 2>&1; then
      builtin eval "fuck ${(q)@}"
    else
      echo "${C_RED}Error: failed to initialize thefuck alias.${C_RESET}" >&2
      return 1
    fi
  }
  alias fk=fuck
fi

# ++++++++++++++++++++++++ PLATFORM-SPECIFIC ALIASES +++++++++++++++++++++++++ #

if [[ "$PLATFORM" == 'macOS' ]]; then
  # ---------- macOS Specific ---------- #

  # TailScale alias for easier access.
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  # --------- macOS utilities ---------- #
  alias update="brew update && brew upgrade"
  alias install="brew install"
  alias search="brew search"
  alias remove="brew remove"
  alias clean="brew cleanup --prune=all"
  alias logs="log show --predicate 'eventMessage contains \"error\"' --info --last 1h"
  alias listening="lsof -i -P | grep LISTEN"
  alias openports="nmap -sT -O localhost"
  alias localip="ipconfig getifaddr en0"
  alias path="echo \$PATH | tr ':' '\n'"
  alias topdir="du -h -d 1 | sort -hr"
  alias flushdns="sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
  alias gotosleep="pmset sleepnow"
  alias lock="pmset displaysleepnow"
  alias battery="pmset -g batt"
  alias emptytrash="osascript -e 'tell application \"Finder\" to empty trash'"
  alias checkds='find . -name ".DS_Store" -type f -print'
  alias rmds='find . -name ".DS_Store" -type f -delete'

elif [[ "$PLATFORM" == 'Linux' ]]; then
  # --------- Linux utilities ---------- #
  # Detect package manager and set aliases accordingly.
  if command -v pacman >/dev/null 2>&1; then
    # Arch Linux
    alias update="sudo pacman -Syu"
    alias install="sudo pacman -S"
    alias search="pacman -Ss"
    alias remove="sudo pacman -R"
    alias autoremove="sudo pacman -Rns \$(pacman -Qtdq)"
  elif command -v apt >/dev/null 2>&1; then
    # Debian/Ubuntu
    alias update="sudo apt update && sudo apt upgrade"
    alias install="sudo apt install"
    alias search="apt search"
    alias remove="sudo apt remove"
    alias autoremove="sudo apt autoremove"
  elif command -v dnf >/dev/null 2>&1; then
    # Fedora/RHEL
    alias update="sudo dnf upgrade"
    alias install="sudo dnf install"
    alias search="dnf search"
    alias remove="sudo dnf remove"
    alias autoremove="sudo dnf autoremove"
  fi
  alias services="systemctl list-units --type=service"
  alias logs="journalctl -f"
  alias ports="ss -tuln"
  alias listening="netstat -tuln"
  alias openports="nmap -sT -O localhost"
  alias firewall="sudo ufw status"
  alias ip="curl -s ifconfig.me"
  # shellcheck disable=SC2142
  alias localip="hostname -I | awk '{print \$1}'"
  alias path="echo \$PATH | tr ':' '\n'"
  alias topdir="du -h --max-depth=1 | sort -hr"
  alias mounted="mount | column -t"
  if command -v trash-empty >/dev/null 2>&1; then
    alias emptytrash='trash-empty'
  elif command -v gio >/dev/null 2>&1; then
    alias emptytrash='gio trash --empty'
  fi

  # ------- Arch Linux Specific -------- #
  if [[ "$ARCH_LINUX" == true ]]; then
    # Note: eza aliases (ld, lt) moved to functions/aliases.zsh

    # Other aliases for Arch.
    command -v kitten >/dev/null 2>&1 && alias kssh='kitten ssh'
    command -v code >/dev/null 2>&1 && alias vc='code'
  fi
fi

# ============================================================================ #
# End of lib/60-aliases.zsh
