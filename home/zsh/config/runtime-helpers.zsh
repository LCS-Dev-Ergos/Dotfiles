#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ SHARED RUNTIME HELPERS ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Foundational helpers shared by startup modules and lazy scripts. Keep this
# file dependency-free: it may be sourced directly outside the normal loader.
#
# Provides:
#   - _zsh_init_colors       Sets C_* color variables.
#   - _zsh_detect_platform   Sets PLATFORM and ARCH_LINUX.
#   - _zsh_mtime             Prints a file's mtime as a Unix timestamp.
#   - _zsh_is_secure_file    Checks ownership/permissions before sourcing.
#   - _zsh_cache_is_fresh    Checks a cache file's security and TTL.
#   - _zsh_cache_put         Writes stdin to a cache file atomically.
#   - _zsh_ui_load           Loads the optional shared presentation layer.
#
# ============================================================================ #

_zsh_runtime_helpers_ready() {
  typeset -f _zsh_init_colors >/dev/null 2>&1 &&
    typeset -f _zsh_detect_platform >/dev/null 2>&1 &&
    typeset -f _zsh_mtime >/dev/null 2>&1 &&
    typeset -f _zsh_is_secure_file >/dev/null 2>&1 &&
    typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 &&
    typeset -f _zsh_cache_put >/dev/null 2>&1 &&
    typeset -f _zsh_ui_load >/dev/null 2>&1
}

if [[ -n "${_ZSH_RUNTIME_HELPERS_LOADED:-}" ]] && _zsh_runtime_helpers_ready; then
  unfunction _zsh_runtime_helpers_ready 2>/dev/null
  return 0
fi

typeset -gi _ZSH_HAS_ZSTAT=0
if zmodload -i zsh/stat 2>/dev/null; then
  _ZSH_HAS_ZSTAT=1
fi

# -----------------------------------------------------------------------------
# _zsh_init_colors
# @internal
# @description Sets C_* color variables when the tty supports 8+ colors,
# empty strings otherwise.
# @noargs
# -----------------------------------------------------------------------------
_zsh_init_colors() {
  if [[ -t 1 ]]; then
    zmodload -i zsh/terminfo 2>/dev/null
    if [[ -n "${terminfo[colors]-}" ]] && (( terminfo[colors] >= 8 )); then
      C_RESET=$'\e[0m'
      C_BOLD=$'\e[1m'
      C_RED=$'\e[31m'
      C_GREEN=$'\e[32m'
      C_YELLOW=$'\e[33m'
      C_BLUE=$'\e[34m'
      C_MAGENTA=$'\e[35m'
      C_CYAN=$'\e[36m'
      return 0
    fi
  fi

  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
}

# -----------------------------------------------------------------------------
# _zsh_detect_platform
# @internal
# @description Detects the OS from OSTYPE and Arch Linux via /etc/arch-release.
# @noargs
# @set PLATFORM string Detected platform: macOS, Linux, or Other.
# @set ARCH_LINUX string "true" on Arch Linux, "false" otherwise.
# -----------------------------------------------------------------------------
_zsh_detect_platform() {
  case "$OSTYPE" in
    darwin*)
      PLATFORM="macOS"
      ARCH_LINUX=false
      ;;
    linux*)
      PLATFORM="Linux"
      [[ -f /etc/arch-release ]] && ARCH_LINUX=true || ARCH_LINUX=false
      ;;
    *)
      PLATFORM="Other"
      ARCH_LINUX=false
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_mtime
# @internal
# @description Prints a file's mtime as a Unix timestamp, via zsh/stat when
# loaded or a portable `stat` fallback (BSD vs GNU flags) otherwise.
# @arg $1 path File to inspect.
# @exitcode 1 If the file cannot be stat'd.
# @stdout The mtime as a Unix timestamp.
# -----------------------------------------------------------------------------
_zsh_mtime() {
  local file="$1"
  local -a stat_info

  if (( _ZSH_HAS_ZSTAT )) && zstat -L -A stat_info +mtime -- "$file" 2>/dev/null; then
    print -r -- "$stat_info[1]"
    return 0
  fi

  if [[ "$OSTYPE" == darwin* ]]; then
    command stat -f %m "$file" 2>/dev/null
  else
    command stat -c %Y "$file" 2>/dev/null
  fi
}

# -----------------------------------------------------------------------------
# _zsh_is_secure_file
# @internal
# @description Checks that a file is a regular, readable, non-symlink file
# owned by the current user and not group/world-writable. Gates every
# `source` of a cache or config file to prevent tampering by other users.
# @arg $1 path File to check.
# @exitcode 1 If the file is not a regular readable file, is a symlink, is
# not owned by EUID, or is group/world-writable.
# -----------------------------------------------------------------------------
_zsh_is_secure_file() {
  local file="$1"
  [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 1

  local -A stat_info
  if (( _ZSH_HAS_ZSTAT )) && zstat -L -H stat_info -- "$file" 2>/dev/null; then
    local mode=$stat_info[mode]
    local uid=$stat_info[uid]
    (( uid == EUID )) || return 1
    (( mode & 8#22 )) && return 1
    return 0
  fi

  local mode uid
  if [[ "$OSTYPE" == darwin* ]]; then
    uid="$(command stat -f %u "$file" 2>/dev/null)" || return 1
    mode="$(command stat -f %Lp "$file" 2>/dev/null)" || return 1
  else
    uid="$(command stat -c %u "$file" 2>/dev/null)" || return 1
    mode="$(command stat -c %a "$file" 2>/dev/null)" || return 1
  fi

  [[ "$uid" =~ ^[0-9]+$ && "$mode" =~ ^[0-9]+$ ]] || return 1
  (( uid == EUID )) || return 1
  (( 8#$mode & 8#22 )) && return 1
  return 0
}

# -----------------------------------------------------------------------------
# _zsh_cache_is_fresh
# @internal
# @description Checks that a cache file is secure and, when a TTL is given,
# was written within the last ttl seconds.
# @arg $1 path Cache file to check.
# @arg $2 integer Optional TTL in seconds; 0 (default) skips the age check.
# @exitcode 1 If the file is insecure or older than the TTL.
# -----------------------------------------------------------------------------
_zsh_cache_is_fresh() {
  local file="$1"
  local ttl="${2:-0}"
  _zsh_is_secure_file "$file" || return 1
  (( ttl > 0 )) || return 0

  local mtime now
  mtime="$(_zsh_mtime "$file")" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now=${EPOCHSECONDS:-$(date +%s)}
  (( now - mtime < ttl ))
}

# -----------------------------------------------------------------------------
# _zsh_cache_put
# @internal
# @description Atomically writes stdin to a user-only (mode 600) cache file,
# via a sibling temp file and `mv`; cleans up the temp file on failure.
# @arg $1 path Destination cache file.
# @exitcode 1 If the directory, temp file, write, or rename fails.
# -----------------------------------------------------------------------------
_zsh_cache_put() {
  emulate -L zsh
  setopt localoptions localtraps
  local file="$1"
  local cache_dir="${file:h}"
  local tmp_file=""

  trap 'return 130' INT TERM HUP
  {
    command mkdir -p -- "$cache_dir" 2>/dev/null || return 1
    tmp_file="$(mktemp "${cache_dir}/.${file:t}.XXXXXX" \
      2>/dev/null)" || return 1
    if ! command cat >| "$tmp_file"; then
      return 1
    fi
    command chmod 600 "$tmp_file" 2>/dev/null || :
    command mv -f -- "$tmp_file" "$file" || return 1
    tmp_file=""
  } always {
    if [[ -n "$tmp_file" ]]; then
      command rm -f -- "$tmp_file" 2>/dev/null
    fi
  }
}

# -----------------------------------------------------------------------------
# _zsh_ui_load
# @internal
# @description Loads the shared UI helpers on first use. This keeps Gum and
# presentation code off the startup path for functions that never render UI.
# @noargs
# @exitcode 1 If the shared helper module is unavailable or cannot be sourced.
# -----------------------------------------------------------------------------
_zsh_ui_load() {
  typeset -f _zsh_ui_log >/dev/null 2>&1 &&
    typeset -f _zsh_ui_table >/dev/null 2>&1 && return 0

  local config_dir="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
  local helpers="$config_dir/scripts/_shared-helpers.zsh"
  [[ -r "$helpers" ]] || {
    print -u2 "Zsh UI helpers not found: $helpers"
    return 1
  }
  source "$helpers"
}

_zsh_detect_platform
_ZSH_RUNTIME_HELPERS_LOADED=1
unfunction _zsh_runtime_helpers_ready 2>/dev/null

# ============================================================================ #
# End of runtime-helpers.zsh
