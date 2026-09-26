#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ LAZY LOADER CORE ENGINE ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Generic lazy-loading engine used by 95-lazy-scripts.zsh and
# 96-lazy-cpp-tools.zsh.  Extracts the shared cache-build, security-check,
# content-signature invalidation, and stub-generation logic into a single
# reusable function.
#
# Usage:
#   _lazy_loader_core <loader_id> <cache_version> <stub_target> <scan_files...>
#
# Parameters:
#   loader_id     Unique identifier (e.g. "scripts", "cpp-tools").
#                 Drives cache filename, generated function names, and
#                 warning-message prefixes.
#   cache_version Integer.  Bump to force cache regeneration.
#   stub_target   "auto" = each discovered name maps to the file it was
#                 found in.  Any other value is treated as an explicit path
#                 and ALL discovered names will map to that script.
#   scan_files    One or more files to parse for function/alias definitions.
#
# ============================================================================ #

typeset -f _zsh_cache_put >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

[[ $- == *i* ]] || return 0

# -----------------------------------------------------------------------------
# _lazy_loader_core
# @internal
# @description Builds and validates a lazy-stub cache from scanned function
# and alias names, then defines self-replacing stub functions for each;
# shared by 95-lazy-scripts.zsh and 96-lazy-cpp-tools.zsh. See the module
# header above for the full parameter contract.
# @arg $1 string Loader id (e.g. "scripts", "cpp-tools").
# @arg $2 integer Cache version; bump to force regeneration.
# @arg $3 string "auto" to map each name to its source file, or an explicit
# script path for every discovered name.
# @arg $@ path Files to scan for function/alias definitions.
# -----------------------------------------------------------------------------
_lazy_loader_core() {
  emulate -L zsh
  setopt noxtrace noverbose

  # ----- Parameter unpacking -------------------------------------------------
  local loader_id="$1"
  local cache_version="$2"
  local stub_target="$3"
  shift 3
  local -a scan_files=("$@")

  (( ${#scan_files} )) || return 0

  # Derive safe identifier for zsh variable/function names (replace - with _).
  local safe_id="${loader_id//-/_}"
  local safe_id_upper="${(U)safe_id}"

  # ----- Cache paths ---------------------------------------------------------
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/lazy-${loader_id}.zsh"
  local msg_prefix="lazy-${loader_id}"

  # ----- Cache signature -----------------------------------------------------
  # The header records each scanned file's path, mtime, size, and inode.
  # Home Manager serves these files from the store with a fixed mtime, so a
  # content change arrives as a different file (inode) behind the same path;
  # in a writable checkout it arrives as a new mtime or size. Either way the
  # stubs are rebuilt. The zstat calls are batched because this runs on
  # every startup.
  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    print -u2 "${msg_prefix}: warning: zsh/stat is unavailable"
    return 1
  }
  local -a signature mtimes sizes inodes
  local -i i
  local file
  if zstat -A mtimes +mtime -- "${scan_files[@]}" 2>/dev/null &&
      zstat -A sizes +size -- "${scan_files[@]}" 2>/dev/null &&
      zstat -A inodes +inode -- "${scan_files[@]}" 2>/dev/null; then
    for (( i = 1; i <= ${#scan_files}; i++ )); do
      signature+=("${scan_files[i]}:${mtimes[i]}:${sizes[i]}:${inodes[i]}")
    done
  else
    # A file vanished mid-scan: force a rebuild rather than trust the cache.
    signature=("unavailable:${EPOCHREALTIME:-$$}")
  fi
  local cache_header="# lazy-${loader_id}-v${cache_version} ${(j:|:)signature}"

  # ---------------------------------------------------------------------------
  # _lazy_core_build_cache
  # @internal
  # @description Scans the files for public function and alias names in one
  # awk pass and atomically writes the self-replacing stub cache.
  # @noargs
  # @exitcode 1 If scanning or writing the cache fails.
  # ---------------------------------------------------------------------------
  _lazy_core_build_cache() {
    local -a readable=()
    local -A seen
    local scan line name key

    for file in "${scan_files[@]}"; do
      [[ -r "$file" ]] && readable+=("$file")
    done
    (( ${#readable} )) || return 1

    # Each output line is "<file><TAB><name>".
    scan="$(command awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*alias[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*=/ {
        line=$0
        sub(/^[[:space:]]*alias[[:space:]]+/, "", line)
        name=line
        sub(/=.*/, "", name)
        print FILENAME "\t" name
        next
      }
      # Match either:
      #   foo() { ... }
      #   function foo() { ... }
      #   function foo { ... }    (zsh-style, no parentheses)
      /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/ ||
      /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\{/ {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^function[[:space:]]+/) sub(/^function[[:space:]]+/, "", line)
        name=line
        sub(/[[:space:]]*(\(\))?[[:space:]]*\{.*/, "", name)
        print FILENAME "\t" name
      }
    ' "${readable[@]}")" || return 1

    for line in "${(@f)scan}"; do
      name="${line#*$'\t'}"
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || continue
      [[ "$name" == _* ]] && continue
      if [[ "$stub_target" == "auto" ]]; then
        seen[$name]="${line%%$'\t'*}"
      else
        seen[$name]="$stub_target"
      fi
    done

    {
      print -r -- "$cache_header"
      print -r -- "# Auto-generated. Do not edit."
      print -r -- "typeset -gA _LAZY_${safe_id_upper}_SOURCED=()"
      print -r -- "_lazy_${safe_id}_source() {"
      print -r -- '  local script="$1"'
      print -r -- "  [[ -n \"\${_LAZY_${safe_id_upper}_SOURCED[\$script]-}\" ]] && return 0"
      print -r -- "  _LAZY_${safe_id_upper}_SOURCED[\$script]=1"
      print -r -- '  if [[ -r "$script" ]]; then'
      print -r -- '    setopt localoptions noxtrace noverbose'
      print -r -- '    source "$script"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- '  return 1'
      print -r -- '}'
      print -r -- "_lazy_${safe_id}_stub() {"
      print -r -- '  local name="$1"'
      print -r -- '  local script="$2"'
      print -r -- '  shift 2'
      print -r -- '  unfunction "$name" 2>/dev/null'
      print -r -- "  _lazy_${safe_id}_source \"\$script\" || return 1"
      print -r -- '  if typeset -f "$name" >/dev/null 2>&1; then'
      print -r -- '    "$name" "$@"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- '  if alias "$name" >/dev/null 2>&1; then'
      print -r -- '    local _alias_cmd="${aliases[$name]}"'
      print -r -- '    ${=_alias_cmd} "$@"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- "  print -u2 \"${msg_prefix}: warning: \$name not found after sourcing script\""
      print -r -- '  return 127'
      print -r -- '}'

      for key in ${(ko)seen}; do
        print -r -- "function ${(q)key}() { _lazy_${safe_id}_stub ${(q)key} ${(q)seen[$key]} \"\$@\"; }"
      done
    } | _zsh_cache_put "$cache_file"
  }

  # ----- Regenerate if needed ------------------------------------------------
  local first_line=""
  if _zsh_is_secure_file "$cache_file"; then
    IFS= read -r first_line < "$cache_file" 2>/dev/null
  fi
  if [[ "$first_line" != "$cache_header" ]] && ! _lazy_core_build_cache; then
    print -u2 "${msg_prefix}: warning: cannot rebuild the stub cache: $cache_file"
  fi
  unfunction _lazy_core_build_cache 2>/dev/null

  # ----- Source cache with security check ------------------------------------
  if _zsh_is_secure_file "$cache_file"; then
    source "$cache_file"
  elif [[ -e "$cache_file" ]]; then
    print -u2 "${msg_prefix}: warning: skipping insecure cache file: $cache_file"
  fi
}

# ============================================================================ #
# # End of lib/94-lazy-loader-core.zsh
