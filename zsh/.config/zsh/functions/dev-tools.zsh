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

# ============================================================================ #
# End of dev-tools.zsh
