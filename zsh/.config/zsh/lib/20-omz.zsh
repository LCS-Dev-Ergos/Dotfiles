#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#                          ██████╗ ███╗   ███╗███████╗
#                         ██╔═══██╗████╗ ████║╚══███╔╝
#                         ██║   ██║██╔████╔██║  ███╔╝
#                         ██║   ██║██║╚██╔╝██║ ███╔╝
#                         ╚██████╔╝██║ ╚═╝ ██║███████╗
#                          ╚═════╝ ╚═╝     ╚═╝╚══════╝
# ============================================================================ #
# +++++++++++++++++++++++++++++ OH-MY-ZSH SETUP ++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Oh-My-Zsh framework initialization with platform-aware plugin management.
# Provides a curated set of plugins for enhanced shell functionality.
#
# Features:
#   - Platform-specific plugin loading (macOS vs. Arch Linux).
#   - Syntax highlighting (must be last plugin).
#   - Autosuggestions and auto-pairing.
#   - Git integration and utility plugins.
#
# Note: zsh-syntax-highlighting must be the last plugin to work correctly.
#
# ============================================================================ #

# On HyDE: this file is loaded only when "HYDE_ZSH_NO_PLUGINS=1".
# The guard below is a safety net for direct sourcing.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
    # HyDE's shell.zsh handles OMZ instead.
    return 0
fi

# Path to Oh-My-Zsh installation (platform specific).
if [[ "$PLATFORM" == "macOS" ]]; then
  export ZSH="$HOME/.oh-my-zsh"
elif [[ "$PLATFORM" == "Linux" ]]; then
  if [[ -d "/usr/share/oh-my-zsh" ]]; then
    export ZSH="/usr/share/oh-my-zsh"
  else
    export ZSH="$HOME/.oh-my-zsh"
  fi
fi

# Set custom directory if needed.
ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.config/zsh}

# Set name of the theme to load.
ZSH_THEME=""

# Keep compfix (compaudit) enabled by default for safer completion loading.
# Set to "true" only if you explicitly want to skip security checks.
: "${ZSH_DISABLE_COMPFIX:=false}"
: "${ZSH_ENABLE_YOU_SHOULD_USE:=0}"

# -----------------------------------------------------------------------------
# _ensure_plugin_installed
# -----------------------------------------------------------------------------
# Automatically installs missing Oh-My-Zsh custom plugins from GitHub.
# Checks if plugin exists in custom plugins directory and clones if missing.
#
# Parameters:
#   $1 - Plugin name (e.g., "zsh-autosuggestions");
#   $2 - GitHub repository URL;
#
# Behavior:
#   - Skips if plugin already exists.
#   - Clones repository to "$ZSH_CUSTOM/plugins/<plugin-name>".
#   - Silent operation unless error occurs.
#
# Usage:
#   _ensure_plugin_installed "zsh-autosuggestions"
# -----------------------------------------------------------------------------
_ensure_plugin_installed() {
  local plugin_name="$1"
  local repo_url="$2"
  local plugin_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin_name"

  # Security: Validate that URL is from GitHub.
  if [[ ! "$repo_url" =~ ^https://github\.com/ ]]; then
    echo "${C_RED}✗ Security error: Only GitHub repositories are allowed${C_RESET}"
    return 1
  fi

  if [[ ! -d "$plugin_dir" ]]; then
    echo "${C_YELLOW}Installing missing plugin: $plugin_name${C_RESET}"
    if git clone --depth=1 "$repo_url" "$plugin_dir" 2>/dev/null; then
      echo "${C_GREEN}✓ Successfully installed $plugin_name${C_RESET}"
    else
      echo "${C_RED}✗ Failed to install $plugin_name${C_RESET}"
      return 1
    fi
  fi
}

# Auto-install required custom plugins if missing.
: "${ZSH_AUTO_INSTALL_PLUGINS:=0}"
if [[ "$ZSH_AUTO_INSTALL_PLUGINS" == "1" && "$PLATFORM" == "macOS" ]]; then
  _ensure_plugin_installed "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
  _ensure_plugin_installed "zsh-history-substring-search" "https://github.com/zsh-users/zsh-history-substring-search"
  _ensure_plugin_installed "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting"
  _ensure_plugin_installed "zsh-autopair" "https://github.com/hlissner/zsh-autopair"
  if [[ "$ZSH_ENABLE_YOU_SHOULD_USE" == "1" ]]; then
    _ensure_plugin_installed "you-should-use" "https://github.com/MichaelAquilina/zsh-you-should-use"
  fi
  _ensure_plugin_installed "zsh-bat" "https://github.com/fdellwing/zsh-bat"
fi

unfunction _ensure_plugin_installed 2>/dev/null
# -----------------------------------------------------------------------------

# Check for plugin availability on Arch Linux.
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # On Arch, prefer system-wide custom directory if it exists,
  # but preserve user's ZSH_CUSTOM if already set to a valid directory with plugins.
  if [[ -z "${ZSH_CUSTOM:-}" ]] || [[ ! -d "$ZSH_CUSTOM/plugins" ]]; then
    if [[ -d "/usr/share/oh-my-zsh/custom" ]]; then
      ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"
    fi
  fi

  # Arch package ships "you-should-use" outside Oh-My-Zsh paths; source it manually.
  if [[ "$ZSH_ENABLE_YOU_SHOULD_USE" == "1" && -f /usr/share/zsh/plugins/zsh-you-should-use/you-should-use.plugin.zsh ]]; then
    source /usr/share/zsh/plugins/zsh-you-should-use/you-should-use.plugin.zsh
  fi
fi

# --------------------------- Plugin Configuration --------------------------- #
# Common plugins for all platforms.
# Note: zsh-syntax-highlighting must be the last plugin to work correctly.
plugins=(
  git
  sudo
  extract
  jsontools
  colored-man-pages
  command-not-found
  copyfile
  copypath
  web-search
)

# Platform-specific plugins.
if [[ "$PLATFORM" == "macOS" ]]; then
  # macOS specific plugins.
  plugins+=(
    zsh-bat
    zsh-autopair
    zsh-autosuggestions
    zsh-history-substring-search
  )
  if [[ "$ZSH_ENABLE_YOU_SHOULD_USE" == "1" ]]; then
    plugins+=(you-should-use)
  fi
  plugins+=(zsh-syntax-highlighting)
elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Arch Linux specific plugins.
  plugins+=(
    fzf
    zsh-256color
    # zsh-autopair
    zsh-autosuggestions
    zsh-history-substring-search
    zsh-syntax-highlighting
  )
fi

# ZSH Cache.
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

# ---------------------------------------------------------------------------- #
# ++++++++++++++++++++++++++ Oh My Zsh Integration +++++++++++++++++++++++++++ #
# ---------------------------------------------------------------------------- #
# This module provides an optimized compinit wrapper that reduces shell startup
# time by caching completion dumps and performing full security checks only
# periodically.
#
# CONFIGURATION:
#   ZSH_COMPINIT_CHECK_HOURS    Hours between full compinit runs (default: 24).
#   ZSH_COMPDUMP                Path to completion dump file.
#   ZSH_DISABLE_COMPFIX         Skip insecure directory checks if "true".
#   PLATFORM                    OS detection variable (e.g., "macOS").
#
# BEHAVIOR:
#   - Fast path: If dump exists and is fresh (< N hours), reuse with -C flag.
#   - Full path: Run complete compinit with security checks and update stamp.
#   - Stamp file tracks last full compinit execution.
#   - Automatically creates cache directory if missing.
#
# FUNCTIONS:
#   _omz_compinit_periodic()    Core wrapper implementing periodic logic.
#   compinit()                  Override that delegates to wrapper, then self-destructs.
#
# NOTES:
#   - The compinit override unloads itself after first use.
#   - Uses XDG_CACHE_HOME for stamp file storage.
#   - Platform-specific stat commands for timestamp retrieval.
#   - Silently handles missing directories and permissions errors.
# ---------------------------------------------------------------------------- #
# Reduce startup cost by running a full compinit only every N hours. Otherwise,
# reuse the cached dump with -C.
: "${ZSH_COMPINIT_CHECK_HOURS:=24}"
_omz_compinit_periodic() {
  setopt localoptions noxtrace noverbose
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local stamp_file="$cache_dir/compinit.last"
  local now epoch_last age_hours

  now=${EPOCHSECONDS:-$(date +%s)}
  epoch_last=0
  if [[ -f "$stamp_file" ]]; then
    if [[ "${PLATFORM:-}" == "macOS" ]]; then
      epoch_last=$(stat -f %m "$stamp_file" 2>/dev/null || echo 0)
    else
      epoch_last=$(stat -c %Y "$stamp_file" 2>/dev/null || echo 0)
    fi
  fi
  age_hours=$(( (now - epoch_last) / 3600 ))

  # Fast path: reuse dump and skip security checks.
  if [[ -f "$ZSH_COMPDUMP" && $age_hours -lt ${ZSH_COMPINIT_CHECK_HOURS:-24} ]]; then
    compinit -C -d "$ZSH_COMPDUMP"
    return $?
  fi

  # Full init path.
  local insecure_mode="-i"
  [[ "$ZSH_DISABLE_COMPFIX" == true ]] && insecure_mode="-u"
  compinit "$insecure_mode" -d "$ZSH_COMPDUMP"
  local rc=$?

  if (( rc == 0 )); then
    mkdir -p "$cache_dir" 2>/dev/null
    touch "$stamp_file" 2>/dev/null || : >| "$stamp_file"
  fi
  return $rc
}

# Override compinit to use periodic wrapper.
compinit() {
  unfunction compinit 2>/dev/null
  autoload -Uz compinit
  _omz_compinit_periodic
  local rc=$?
  unfunction _omz_compinit_periodic 2>/dev/null
  return $rc
}

source "$ZSH/oh-my-zsh.sh"

# ------------------------- History Substring Search ------------------------- #
# Keybindings for zsh-history-substring-search plugin.
# Must be loaded AFTER oh-my-zsh.sh to work correctly.
if [[ -n "${plugins[(r)zsh-history-substring-search]}" ]]; then
  # Bind Up/Down arrow keys.
  bindkey '^[[A' history-substring-search-up
  bindkey '^[[B' history-substring-search-down

  # Bind k and j for vi mode.
  bindkey -M vicmd 'k' history-substring-search-up
  bindkey -M vicmd 'j' history-substring-search-down

  # Plugin configuration.
  HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND='bg=green,fg=black,bold'
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND='bg=red,fg=black,bold'
fi

# ============================================================================ #
# End of 20-omz.zsh
