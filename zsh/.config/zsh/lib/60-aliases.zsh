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
# +++++++++++++++++++++++++++ ALIASES & FUNCTIONS ++++++++++++++++++++++++++++ #
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
# Platform detection via $PLATFORM variable from 00-init.zsh
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
# Change directory to the parent folder of a file selected via fzf.
# Interactive file picker that navigates to the containing directory.
#
# Returns:
#   0 - Successfully changed directory.
#   1 - fzf not available or no file selected.
#
# Dependencies:
#   fzf - Fuzzy finder.
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
alias fnm-clean='echo "${C_CYAN}Cleaning up orphaned fnm sessions...${C_RESET}" &&
rm -rf ~/.local/state/fnm_multishells/* && echo "${C_GREEN}Cleanup completed.${C_RESET}"'

# ++++++++++++++++++++++++++++ C/C++ COMPILATION +++++++++++++++++++++++++++++ #

# ---------- C Include Path ---------- #
# Determine include path dynamically based on platform.
if [[ "$PLATFORM" == 'macOS' ]] && [[ -d "/opt/homebrew/include" ]]; then
  C_INCLUDE_PATH="-I/opt/homebrew/include"
elif [[ -d "/usr/local/include" ]]; then
  C_INCLUDE_PATH="-I/usr/local/include"
else
  C_INCLUDE_PATH=""
fi

# Toolchain Information Alias.
alias toolchain='ZSH_HIGHLIGHT_MAXLENGTH=0 get_toolchain_info 2> >(grep -v "^[a-z_]*=")'

# Default C Compilation Alias.
alias c-compile="clang -std=c23 -O3 -march=native -flto=thin -ffast-math $C_INCLUDE_PATH"

# GCC C Compilation.
alias gcc-c-compile="gcc -std=c23 -O3 -march=native -flto -ffast-math $C_INCLUDE_PATH"
alias gcc-c-debug="gcc -std=c23 -g -O0 -Wall -Wextra -DDEBUG $C_INCLUDE_PATH"

# Clang C Compilation.
alias clang-c-compile="clang -std=c23 -O3 -march=native -flto=thin -ffast-math $C_INCLUDE_PATH"
alias clang-c-debug="clang -std=c23 -g -O0 -Wall -Wextra -DDEBUG $C_INCLUDE_PATH"

# Ultra Performance Clang C with ThinLTO and PGO.
alias clang-c-ultra="clang -std=c23 -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-generate=default.profraw -funroll-loops -fvectorize \
    $C_INCLUDE_PATH"
alias clang-c-ultra-use="clang -std=c23 -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-use=default.profdata -funroll-loops -fvectorize \
    $C_INCLUDE_PATH"

# Quick C compilation aliases.
alias qc-compile="clang -std=c23 -O2 $C_INCLUDE_PATH"
alias qc-debug="clang -std=c23 -g -O0 -Wall $C_INCLUDE_PATH"

# --------- C++ Compilation ---------- #
# Determine LLVM library path dynamically.
if [[ "$PLATFORM" == 'macOS' ]]; then
  if [[ -d "/opt/homebrew/opt/llvm/lib/c++" ]]; then
    LLVM_PREFIX="/opt/homebrew/opt/llvm"
  elif [[ -d "/usr/local/opt/llvm/lib/c++" ]]; then
    LLVM_PREFIX="/usr/local/opt/llvm"
  fi
  if [[ -n "${LLVM_PREFIX:-}" && -d "$LLVM_PREFIX/lib/c++" ]]; then
    CPP_LIB_PATH="-L$LLVM_PREFIX/lib/c++ -lc++"
  else
    CPP_LIB_PATH="-lc++"
  fi
else
  CPP_LIB_PATH="-lc++"
fi

# Default C++ Compilation Alias.
alias compile="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH \
    -O3 -march=native -flto=thin -ffast-math $C_INCLUDE_PATH"

# GCC Compilation.
alias gcc-compile="g++ -std=c++23 -O3 -march=native -flto -ffast-math $C_INCLUDE_PATH"
alias gcc-debug="g++ -std=c++23 -g -O0 -Wall -Wextra -DDEBUG $C_INCLUDE_PATH"

# Clang Compilation.
alias clang-compile="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH \
    -O3 -march=native -flto=thin -ffast-math $C_INCLUDE_PATH"
alias clang-debug="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH \
    -g -O0 -Wall -Wextra -DDEBUG $C_INCLUDE_PATH"

# Ultra Performance Clang with ThinLTO and PGO.
alias clang-ultra="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-generate=default.profraw -funroll-loops -fvectorize \
    $C_INCLUDE_PATH"
alias clang-ultra-use="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH -O3 -march=native -mtune=native \
    -flto=thin -ffast-math -fprofile-use=default.profdata -funroll-loops -fvectorize \
    $C_INCLUDE_PATH"

# Quick compilation aliases.
alias qcompile="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH -O2 $C_INCLUDE_PATH"
alias qdebug="clang++ -std=c++23 -stdlib=libc++ $CPP_LIB_PATH -g -O0 -Wall $C_INCLUDE_PATH"

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

# -----------------------------------------------------------------------------
# zsh_profile
# -----------------------------------------------------------------------------
# Profile shell startup time and optionally show zprof output.
#
# Usage:
#   zsh_profile            # timing only
#   zsh_profile zprof      # zprof table
#   zsh_profile both       # timing + zprof
# -----------------------------------------------------------------------------
zsh_profile() {
  local mode="${1:-time}"
  local zdot="${ZSH_CONFIG_DIR:-${ZDOTDIR:-$HOME/.config/zsh}}"
  local zsh_bin="${ZSH_PROFILE_ZSH_BIN:-$(command -v zsh)}"
  local fast="${ZSH_PROFILE_FAST_START:-}"

  if [[ ! -f "$zdot/.zshrc" ]]; then
    zdot="${ZDOTDIR:-$HOME}"
  fi

  # Find a suitable time command (GNU time preferred for -p flag).
  local time_cmd=""
  if [[ -x /usr/bin/time ]]; then
    time_cmd="/usr/bin/time -p"
  elif command -v gtime >/dev/null 2>&1; then
    time_cmd="gtime -p"
  fi

  # Helper to run timed command.
  _zsh_profile_timed() {
    if [[ -n "$time_cmd" ]]; then
      command ${=time_cmd} env ZDOTDIR="$zdot" ZSH_FAST_START="$fast" "$zsh_bin" -i -c exit
    else
      # Fallback to zsh time builtin (less precise, different format).
      TIMEFMT=$'real\t%*E\nuser\t%*U\nsys\t%*S'
      time (env ZDOTDIR="$zdot" ZSH_FAST_START="$fast" "$zsh_bin" -i -c exit)
    fi
  }

  # Mode selection.
  case "$mode" in
    time|--time)
      _zsh_profile_timed
      ;;
    zprof|--zprof)
      env ZDOTDIR="$zdot" ZSH_PROFILE=1 ZSH_FAST_START="$fast" "$zsh_bin" -i -c 'zmodload zsh/zprof; zprof'
      ;;
    both|--both)
      _zsh_profile_timed
      env ZDOTDIR="$zdot" ZSH_PROFILE=1 ZSH_FAST_START="$fast" "$zsh_bin" -i -c 'zmodload zsh/zprof; zprof'
      ;;
    *)
      echo "Usage: zsh_profile [time|zprof|both]" >&2
      return 1
      ;;
  esac
}

# Note: eza/bat/duf aliases moved to functions/aliases.zsh

# ++++++++++++++++++++++++++++++ kitty Terminal ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# kreload
# -----------------------------------------------------------------------------
# Reload Kitty configuration without restarting the terminal.
# Uses SIGUSR1 signal to trigger live reload.
#
# Returns:
#   0 - Configuration reloaded successfully.
#   1 - Not running in Kitty or reload failed.
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
# Manually set the terminal window/tab title.
# Useful when auto-titling is disabled.
#
# Usage:
#   stitle "My Title"
# -----------------------------------------------------------------------------
function stitle() {
  echo -en "\e]2;$@\a"
}

# +++++++++++++++++++++++++++ THEFUCK INTEGRATION ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# fuck
# -----------------------------------------------------------------------------
# Lazy-load and create an alias for 'thefuck' command.
#
# Returns:
#   Corrects mistyped commands.
#
# Notes:
#   Aliases expand at parse time so we can't call the alias immediately from
#   the function; due to history-expansion complexities with "thefuck", the
#   workaround is to either ask the user to run it again or execute the alias's
#   underlying command (raw command) once instead.
# -----------------------------------------------------------------------------
if command -v thefuck >/dev/null 2>&1; then
  # Lazy load thefuck to save startup time.
  fuck() {
    unset -f fuck
    eval "$(thefuck --alias 2>/dev/null)"
    # The alias is now defined, invoke it.
    eval "$functions[fuck]" "$@"
    # Check if alias was created successfully.
    if alias fuck >/dev/null 2>&1; then
      # Invoke the alias.
      PYTHONIOENCODING=utf-8 thefuck $(fc -ln -1 | tail -n 1) && fc -R
    fi
  }
  alias fk=fuck
fi

# ++++++++++++++++++++++++ PLATFORM-SPECIFIC ALIASES +++++++++++++++++++++++++ #

if [[ "$PLATFORM" == 'macOS' ]]; then
  # ---------- macOS Specific ---------- #

  # TailScale alias for easier access.
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  # ---------------------------------------------------------------------------
  # brew
  # ---------------------------------------------------------------------------
  # Homebrew wrapper that triggers sketchybar updates after package operations.
  # Automatically notifies sketchybar when packages are updated/upgraded.
  #
  # Triggers:
  #   - Sends brew_update trigger to sketchybar after update/upgrade/outdated
  # ---------------------------------------------------------------------------
  function brew() {
    command brew "$@"
    case "${1:-}" in
      upgrade|update|outdated)
        # Ensure sketchybar is available before calling it.
        # Run asynchronously (&!) to avoid blocking the terminal if sketchybar hangs.
        command -v sketchybar >/dev/null 2>&1 && sketchybar --trigger brew_update &!
        ;;
    esac
  }

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
    # -------------------------------------------------------------------------
    # command_not_found_handler (toggleable)
    # -------------------------------------------------------------------------
    # Arch Linux command not found handler using pacman file database.
    # Set ENABLE_CMD_NOT_FOUND=true to re-enable suggestions; defaults to off
    # to avoid the lookup overhead when a typo occurs.
    : "${ENABLE_CMD_NOT_FOUND:=false}"

    if [[ "${ENABLE_CMD_NOT_FOUND}" == true ]]; then
      function command_not_found_handler {
        # Use $'\e' so colors contain the real escape byte, not the literal "\e".
        local purple=$'\e[1;35m' bright=$'\e[0;1m' green=$'\e[1;32m' reset=$'\e[0m'
        printf 'zsh: command not found: %s\n' "$1"
        # shellcheck disable=SC2296
        local entries=( "${(f)"$(/usr/bin/pacman -F --machinereadable -- "/usr/bin/$1")"}" )
        if (( ${#entries[@]} )); then
          printf '%s may be found in the following packages:\n' "${bright}$1${reset}"
          local pkg
          for entry in "${entries[@]}" ; do
            # shellcheck disable=SC2296
            local fields=( "${(0)entry}" )
            if [[ "$pkg" != "${fields[2]}" ]]; then
              printf "${purple}%s/${bright}%s ${green}%s${reset}\n" "${fields[1]}" "${fields[2]}" "${fields[3]}"
            fi
            printf '    /%s\n' "${fields[4]}"
            pkg="${fields[2]}"
          done
        fi
        return 127
      }
    fi

    # Automatic detection of AUR helper.
    if pacman -Qi yay &>/dev/null; then
      aurhelper="yay"
    elif pacman -Qi paru &>/dev/null; then
      aurhelper="paru"
    fi

    # -------------------------------------------------------------------------
    # in
    # -------------------------------------------------------------------------
    # Intelligent package installer for Arch Linux.
    # Automatically determines whether packages are in official repos or AUR
    # and uses the appropriate tool (pacman or AUR helper).
    #
    # Usage:
    #   in <package1> [package2] [package3] ...
    #
    # Arguments:
    #   package1, package2, ... - Package names to install.
    #
    # Returns:
    #   0 - All packages installed successfully.
    #   1 - Installation failed or no AUR helper available for AUR packages.
    # -------------------------------------------------------------------------
    function in {
      local -a inPkg=("$@")
      local -a arch=()
      local -a aur=()

      for pkg in "${inPkg[@]}"; do
        if pacman -Si "${pkg}" &>/dev/null; then
          arch+=("${pkg}")
        else
          aur+=("${pkg}")
        fi
      done

      if [[ ${#arch[@]} -gt 0 ]]; then
        sudo pacman -S --needed "${arch[@]}"
      fi

      if [[ ${#aur[@]} -gt 0 ]] && [[ -n "$aurhelper" ]]; then
        ${aurhelper} -S --needed "${aur[@]}"
      fi
    }

    # Aliases for package management on Arch.
    if [[ -n "$aurhelper" ]]; then
      alias un='$aurhelper -Rns'
      alias up='$aurhelper -Syu'
      alias pl='$aurhelper -Qs'
      alias pa='$aurhelper -Ss'
      alias pc='$aurhelper -Sc'
      alias po='pacman -Qtdq | $aurhelper -Rns -'
    fi

    # Note: eza aliases (ld, lt) moved to functions/aliases.zsh

    # Other aliases for Arch.
    command -v kitten >/dev/null 2>&1 && alias kssh='kitten ssh'
    command -v code >/dev/null 2>&1 && alias vc='code'
  fi
fi

# ============================================================================ #
# End of 60-aliases.zsh
