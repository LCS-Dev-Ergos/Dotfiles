#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ DEV TOOLS FUNCTIONS ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Development-related utilities.
# Functions to streamline coding workflows and environment setup.
#
# Functions:
#   - clang_format_link   Create symlink to global .clang-format config.
#   - sysinfo             Display comprehensive system information.
#   - zbench              Run zsh-bench from the shared tools directory.
#   - fnm_clean           Clean stale fnm multishell symlinks.
#   - zsh_profile         Profile shell startup time and zprof output.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# clang_format_link
# -----------------------------------------------------------------------------
# Create a symbolic link to the global .clang-format configuration file
# in the current directory. Prompts before overwriting existing files.
#
# Usage:
#   clang_format_link
#
# Returns:
#   0 - Symbolic link created successfully or operation cancelled.
#   1 - Global config file not found or link creation failed.
# -----------------------------------------------------------------------------
function clang_format_link() {
  local config_file="$HOME/.config/clang-format/.clang-format"
  local target_file="./.clang-format"

  # Check if global config file exists.
  if [[ ! -f "$config_file" ]]; then
    echo "${C_RED}Error: Global .clang-format file not found at '$config_file'${C_RESET}" >&2
    return 1
  fi

  # Check if target already exists.
  if [[ -e "$target_file" ]]; then
    if [[ -L "$target_file" ]]; then
      local current_target=$(readlink "$target_file")
      if [[ "$current_target" == "$config_file" ]]; then
        echo "${C_YELLOW}Symbolic link already exists and points to the correct file.${C_RESET}"
        return 0
      else
        echo "${C_YELLOW}Symbolic link exists but points to: $current_target${C_RESET}"
      fi
    else
      echo "${C_YELLOW}File '.clang-format' already exists in current directory.${C_RESET}"
    fi

    echo -n "${C_YELLOW}Replace existing file/link? (y/N): ${C_RESET}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "${C_CYAN}Operation cancelled.${C_RESET}"
      return 0
    fi

    rm -f "$target_file"
  fi

  # Create the symbolic link.
  echo "${C_CYAN}Creating symbolic link to .clang-format configuration...${C_RESET}"

  if ln -s "$config_file" "$target_file" 2>/dev/null; then
    echo "${C_GREEN}✓ Successfully created symbolic link: .clang-format → $config_file${C_RESET}"

    # Show the link details.
    if command -v ls >/dev/null 2>&1; then
      ls -la "$target_file"
    fi
  else
    echo "${C_RED}Error: Failed to create symbolic link.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# sysinfo
# -----------------------------------------------------------------------------
# Display comprehensive system information including OS, CPU, memory, disk,
# network interfaces, and uptime. Platform-aware (macOS/Linux).
#
# Usage:
#   sysinfo    - Display system information.
# -----------------------------------------------------------------------------
function sysinfo() {
  echo "${C_CYAN}/===----------- System Information -----------===/${C_RESET}"

  # OS Information.
  echo "${C_YELLOW}OS:${C_RESET}"
  if [[ "$PLATFORM" == "macOS" ]]; then
    sw_vers
  elif [[ "$PLATFORM" == "Linux" ]]; then
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      echo "  $NAME $VERSION"
    fi
    uname -a
  fi

  # CPU Information.
  echo -e "\n${C_YELLOW}CPU:${C_RESET}"
  if [[ "$PLATFORM" == "macOS" ]]; then
    sysctl -n machdep.cpu.brand_string
    echo "  Cores: $(sysctl -n hw.ncpu)"
  elif [[ "$PLATFORM" == "Linux" ]]; then
    grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2
    echo "  Cores: $(nproc)"
  fi

  # Memory Information.
  echo -e "\n${C_YELLOW}Memory:${C_RESET}"
  if [[ "$PLATFORM" == "macOS" ]]; then
    local total_mem=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
    echo "  Total: ${total_mem}GB"
  elif [[ "$PLATFORM" == "Linux" ]]; then
    free -h | grep "^Mem:" | awk '{print "  Total: " $2 ", Used: " $3 ", Free: " $4}'
  fi

  # Disk Information.
  echo -e "\n${C_YELLOW}Disk Usage:${C_RESET}"
  df -h | grep -E "^/dev/" | awk '{print "  " $1 ": " $5 " used (" $4 " free)"}'

  # Network Information.
  echo -e "\n${C_YELLOW}Network:${C_RESET}"
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print "  " $2}'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print "  " $2}'
  fi

  # Uptime.
  echo -e "\n${C_YELLOW}Uptime:${C_RESET}"
  uptime
}

# -----------------------------------------------------------------------------
# zbench
# -----------------------------------------------------------------------------
# Run zsh-bench from $ZSH_BENCH_DIR (or default XDG tools location).
#
# Usage:
#   zbench [zsh-bench args...]
#
# Examples:
#   zbench --iters 20 --raw
#   zbench --help
# -----------------------------------------------------------------------------
function zbench() {
  local bench_dir="${ZSH_BENCH_DIR:-${ZSH_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/tools}/zsh-bench}"
  local bench_cmd="$bench_dir/zsh-bench"

  if [[ ! -x "$bench_cmd" ]]; then
    echo "${C_RED}Error: zsh-bench not found at '$bench_cmd'.${C_RESET}" >&2
    echo "${C_YELLOW}Install with:${C_RESET} git clone https://github.com/romkatv/zsh-bench \"$bench_dir\"" >&2
    return 1
  fi

  "$bench_cmd" "$@"
}

# -----------------------------------------------------------------------------
# fnm_clean
# -----------------------------------------------------------------------------
# Safely cleanup stale fnm multishell symlinks.
# Default: removes only orphan sessions (PID not running).
# Flags:
#   --all      Remove all symlinks (including active sessions).
#   --dry-run  Show what would be removed.
#   --quiet    Suppress info output.
# -----------------------------------------------------------------------------
function fnm_clean() {
  emulate -L zsh
  setopt noxtrace noverbose nullglob

  local fnm_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/fnm_multishells"
  local remove_all=0
  local dry_run=0
  local quiet=0
  local arg

  for arg in "$@"; do
    case "$arg" in
      --all) remove_all=1 ;;
      --dry-run|-n) dry_run=1 ;;
      --quiet) quiet=1 ;;
      -h|--help)
        cat <<'EOF'
Usage: fnm_clean [--all] [--dry-run|-n] [--quiet]

Default behavior removes only orphan fnm multishell symlinks.
Use --all to remove every symlink in the fnm multishell state directory.
EOF
        return 0
        ;;
      *)
        echo "fnm_clean: unknown option '$arg'" >&2
        return 2
        ;;
    esac
  done

  if [[ ! -d "$fnm_state_dir" ]]; then
    (( quiet )) || echo "${C_YELLOW}fnm state directory not found: $fnm_state_dir${C_RESET}"
    return 0
  fi

  local -a links=("$fnm_state_dir"/*(N@))
  if (( ${#links[@]} == 0 )); then
    (( quiet )) || echo "${C_CYAN}No fnm multishell symlinks to clean.${C_RESET}"
    return 0
  fi

  (( quiet )) || echo "${C_CYAN}Cleaning fnm multishell symlinks...${C_RESET}"

  local removed=0 skipped=0 failed=0
  local link base pid

  for link in "${links[@]}"; do
    if (( ! remove_all )); then
      # Keep current shell session symlink when available.
      if [[ -n "${FNM_MULTISHELL_PATH:-}" && "$link" == "$FNM_MULTISHELL_PATH" ]]; then
        ((skipped++))
        continue
      fi

      # fnm multishell names are "<pid>_<timestamp>"; keep running PIDs.
      base="${link:t}"
      pid="${base%%_*}"
      if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
        ((skipped++))
        continue
      fi
    fi

    if (( dry_run )); then
      (( quiet )) || print -r -- "would remove: $link"
      ((removed++))
      continue
    fi

    if command rm -f -- "$link"; then
      ((removed++))
    else
      ((failed++))
    fi
  done

  if (( dry_run )); then
    (( quiet )) || echo "${C_GREEN}Dry-run completed. Candidates: $removed, skipped(active): $skipped.${C_RESET}"
    return 0
  fi

  if (( failed > 0 )); then
    (( quiet )) || echo "${C_YELLOW}Cleanup completed with errors. Removed: $removed, skipped(active): $skipped, failed: $failed.${C_RESET}"
    return 1
  fi

  (( quiet )) || echo "${C_GREEN}Cleanup completed. Removed: $removed, skipped(active): $skipped.${C_RESET}"
  return 0
}

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
function zsh_profile() {
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

# ============================================================================ #
# End of dev-tools.zsh
