#!/usr/bin/env zsh
# shellcheck shell=zsh
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
    git clone --depth=1 "$repo_url" "$plugin_dir" 2>/dev/null
    if [[ $? -eq 0 ]]; then
      echo "${C_GREEN}✓ Successfully installed $plugin_name${C_RESET}"
    else
      echo "${C_RED}✗ Failed to install $plugin_name${C_RESET}"
      return 1
    fi
  fi
}

# Auto-install required custom plugins if missing
if [[ "$PLATFORM" == "macOS" ]]; then
  _ensure_plugin_installed "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
  _ensure_plugin_installed "zsh-history-substring-search" "https://github.com/zsh-users/zsh-history-substring-search"
  _ensure_plugin_installed "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting"
  _ensure_plugin_installed "zsh-autopair" "https://github.com/hlissner/zsh-autopair"
  _ensure_plugin_installed "you-should-use" "https://github.com/MichaelAquilina/zsh-you-should-use"
  _ensure_plugin_installed "zsh-bat" "https://github.com/fdellwing/zsh-bat"
fi
# -----------------------------------------------------------------------------

# Check for plugin availability on Arch Linux.
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Make sure the ZSH_CUSTOM path is set correctly for Arch Linux.
  ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"

  # Arch package ships "you-should-use" outside Oh-My-Zsh paths; source it manually.
  if [[ -f /usr/share/zsh/plugins/zsh-you-should-use/you-should-use.plugin.zsh ]]; then
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
    you-should-use
    zsh-autosuggestions
    zsh-history-substring-search
    zsh-syntax-highlighting
  )
elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Arch Linux specific plugins.
  plugins+=(
    fzf
    zsh-256color
    zsh-autopair
    you-should-use
    zsh-autosuggestions
    zsh-history-substring-search
    zsh-syntax-highlighting
  )
fi

# ZSH Cache.
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

source "$ZSH/oh-my-zsh.sh"

# ---------------------- History Substring Search ---------------------------- #
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
