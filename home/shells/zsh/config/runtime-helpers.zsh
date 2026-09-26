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
#   - _zsh_mtime             Stores a file's mtime (Unix timestamp) in REPLY.
#   - _zsh_is_secure_file    Checks ownership/permissions before sourcing.
#   - _zsh_cache_is_fresh    Checks a cache file's security and TTL.
#   - _zsh_cache_put         Writes stdin to a cache file atomically.
#   - _zsh_cached_init       Evaluates a tool's init script through a cache.
#   - _zsh_fpath_prepend     Prepends existing directories to fpath once.
#   - _zsh_compinit_signature  Describes fpath for the completion dump.
#   - _zsh_ui_load           Loads the optional shared presentation layer.
#
# Helpers that return a value use REPLY instead of stdout: `$(helper)` would
# fork a subshell, and these run on the startup path.
#
# ============================================================================ #

_zsh_runtime_helpers_ready() {
  typeset -f _zsh_init_colors >/dev/null 2>&1 &&
    typeset -f _zsh_detect_platform >/dev/null 2>&1 &&
    typeset -f _zsh_mtime >/dev/null 2>&1 &&
    typeset -f _zsh_is_secure_file >/dev/null 2>&1 &&
    typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 &&
    typeset -f _zsh_cache_put >/dev/null 2>&1 &&
    typeset -f _zsh_cached_init >/dev/null 2>&1 &&
    typeset -f _zsh_fpath_prepend >/dev/null 2>&1 &&
    typeset -f _zsh_compinit_signature >/dev/null 2>&1 &&
    typeset -f _zsh_ui_load >/dev/null 2>&1
}

if [[ -n "${_ZSH_RUNTIME_HELPERS_LOADED:-}" ]] && _zsh_runtime_helpers_ready; then
  unfunction _zsh_runtime_helpers_ready 2>/dev/null
  return 0
fi

# Only zstat: the module's other builtin is named `stat` and would shadow
# /usr/bin/stat, with a different syntax, at the interactive prompt.
typeset -gi _ZSH_HAS_ZSTAT=0
if zmodload -F zsh/stat b:zstat -b:stat 2>/dev/null; then
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
# @description Stores a file's mtime as a Unix timestamp in REPLY, via
# zsh/stat when loaded (no fork) or a portable `stat` fallback (BSD vs GNU
# flags) otherwise. Symlinks are not followed.
# @arg $1 path File to inspect.
# @exitcode 1 If the file cannot be stat'd.
# @set REPLY integer The mtime as a Unix timestamp; empty on failure.
# -----------------------------------------------------------------------------
_zsh_mtime() {
  local file="$1"
  local -a stat_info
  REPLY=""

  if (( _ZSH_HAS_ZSTAT )) && zstat -L -A stat_info +mtime -- "$file" 2>/dev/null; then
    REPLY="$stat_info[1]"
    return 0
  fi

  if [[ "$OSTYPE" == darwin* ]]; then
    REPLY="$(command stat -f %m "$file" 2>/dev/null)"
  else
    REPLY="$(command stat -c %Y "$file" 2>/dev/null)"
  fi
  [[ "$REPLY" == <-> ]] || { REPLY=""; return 1; }
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

  local REPLY now
  _zsh_mtime "$file" || return 1
  now=${EPOCHSECONDS:-$(date +%s)}
  (( now - REPLY < ttl ))
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
# _zsh_cached_init
# @internal
# @description Evaluates the shell-init script a tool prints, reusing a
# user-only cache while the executable is unchanged. The key is the
# symlink-resolved executable: Nix and Homebrew upgrades land on a new store
# or Cellar path, and in-place rebuilds leave a binary newer than the cache.
# The script is always sourced from the cache file, never eval'd as one
# string: eval parses everything before running anything, so a script that
# turns aliases off for its own definitions (fzf's does) would have them
# expanded anyway, and only in the shell that regenerated the cache.
# @option -f <function> Filter that may rewrite the generated script held in
# REPLY before it is evaluated and cached. Its definition is part of the key,
# so editing the filter regenerates the cache.
# @arg $1 string Cache name; selects init-<name>.zsh below the Zsh cache.
# @arg $2 path Executable that prints the init script.
# @arg $@ string Arguments that make the executable print its init script.
# @exitcode 1 If the executable is unusable or the init script fails.
# -----------------------------------------------------------------------------
_zsh_cached_init() {
  # Prefixed locals keep the evaluated script from assigning to our state.
  local __zci_filter=""
  if [[ "$1" == -f ]]; then
    __zci_filter="$2"
    shift 2
  fi
  local __zci_name="$1" __zci_bin="$2"
  shift 2
  [[ -n "$__zci_name" && -n "$__zci_bin" && -x "$__zci_bin" ]] || return 1

  local __zci_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/init-${__zci_name}.zsh"
  local __zci_header="# init-cache-v1 ${__zci_bin:A} ${(j: :)${(@q)@}}"
  # (q+) keeps the multi-line definition on the single header line.
  [[ -z "$__zci_filter" ]] ||
    __zci_header+=" | $__zci_filter ${(q+)functions[$__zci_filter]-}"
  local __zci_cached=""

  if _zsh_cache_is_fresh "$__zci_file"; then
    IFS= read -r __zci_cached < "$__zci_file"
    if [[ "$__zci_cached" == "$__zci_header" &&
          "$__zci_file" -nt "$__zci_bin" ]]; then
      source "$__zci_file"
      return
    fi
  fi

  local REPLY
  REPLY="$("$__zci_bin" "$@" 2>/dev/null)" && [[ -n "$REPLY" ]] || return 1
  if [[ -n "$__zci_filter" ]]; then
    "$__zci_filter" || return 1
  fi
  local __zci_code="$REPLY"
  if print -r -- "$__zci_header"$'\n'"$__zci_code" |
      _zsh_cache_put "$__zci_file" 2>/dev/null &&
      _zsh_is_secure_file "$__zci_file"; then
    source "$__zci_file"
    return
  fi
  # No usable cache directory: evaluate the output directly.
  eval "$__zci_code"
}

# -----------------------------------------------------------------------------
# _zsh_fpath_prepend
# @internal
# @description Prepends each existing directory to fpath unless it is
# already present, keeping the argument order as the priority order.
# @arg $@ path Completion directories, highest priority first.
# @exitcode 1 If no directory was added.
# -----------------------------------------------------------------------------
_zsh_fpath_prepend() {
  local dir
  local -a added=()
  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    (( ${fpath[(Ie)$dir]} || ${added[(Ie)$dir]} )) || added+=("$dir")
  done
  (( ${#added} )) || return 1
  fpath=("${added[@]}" "${fpath[@]}")
}

# -----------------------------------------------------------------------------
# _zsh_compinit_signature
# @internal
# @description Describes what a completion dump was built from: the dump path
# plus every fpath directory with its inode and mtime. A switch that swaps a
# symlinked directory for another store path changes the inode; installing or
# removing a completion changes the mtime. Either way the signature no longer
# matches and the next compinit rebuilds the dump instead of trusting -C.
# @noargs
# @set REPLY string The signature.
# -----------------------------------------------------------------------------
_zsh_compinit_signature() {
  local -a dirs inodes mtimes parts
  local -i i
  # (N-/): existing directories, symlinks followed.
  dirs=(${^fpath}(N-/))
  if (( _ZSH_HAS_ZSTAT && ${#dirs} )) &&
      zstat -A inodes +inode -- "${dirs[@]}" 2>/dev/null &&
      zstat -A mtimes +mtime -- "${dirs[@]}" 2>/dev/null; then
    for (( i = 1; i <= ${#dirs}; i++ )); do
      parts+=("${dirs[i]}:${inodes[i]}:${mtimes[i]}")
    done
  else
    parts=("${fpath[@]}")
  fi
  REPLY="v2|${ZSH_COMPDUMP-}|${(j.|.)parts}"
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
