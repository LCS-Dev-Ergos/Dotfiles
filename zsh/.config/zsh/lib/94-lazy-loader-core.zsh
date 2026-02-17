#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ LAZY LOADER CORE ENGINE ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Generic lazy-loading engine used by 95-lazy-scripts.zsh and
# 96-lazy-cpp-tools.zsh.  Extracts the shared cache-build, security-check,
# mtime-invalidation, and stub-generation logic into a single reusable
# function.
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
[[ $- == *i* ]] || return 0

_lazy_loader_core() {
  emulate -L zsh
  setopt noxtrace noverbose

  # ----- Parameter unpacking ------------------------------------------------ #
  local loader_id="$1"
  local cache_version="$2"
  local stub_target="$3"
  shift 3
  local -a scan_files=("$@")

  (( ${#scan_files} )) || return 0

  # Derive safe identifier for zsh variable/function names (replace - with _).
  local safe_id="${loader_id//-/_}"
  local safe_id_upper="${(U)safe_id}"

  # ----- Cache paths -------------------------------------------------------- #
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local cache_file="$cache_dir/lazy-${loader_id}.zsh"
  local cache_header="# lazy-${loader_id}-version: ${cache_version}"
  local msg_prefix="lazy-${loader_id}"

  # ----- Build cache -------------------------------------------------------- #
  _lazy_core_build_cache() {
    local out_file="$1"
    shift
    local -a files=("$@")
    local tmp_file="${out_file}.tmp.$$"
    local -A seen

    trap "rm -f ${(q)tmp_file} 2>/dev/null" EXIT INT TERM

    local file name
    local -a names
    for file in "${files[@]}"; do
      [[ -r "$file" ]] || continue
      names=("${(@f)$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*alias[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*=/ {
          line=$0
          sub(/^[[:space:]]*alias[[:space:]]+/, "", line)
          name=line
          sub(/=.*/, "", name)
          print name
          next
        }
        /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/ {
          line=$0
          sub(/^[[:space:]]*/, "", line)
          if (line ~ /^function[[:space:]]+/) sub(/^function[[:space:]]+/, "", line)
          name=line
          sub(/[[:space:]]*\(\).*/, "", name)
          print name
        }
      ' "$file")}")

      for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || continue
        if [[ "$stub_target" == "auto" ]]; then
          seen[$name]="$file"
        else
          seen[$name]="$stub_target"
        fi
      done
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

      local key
      for key in ${(k)seen}; do
        local script_path="${seen[$key]}"
        print -r -- "function ${(q)key}() { _lazy_${safe_id}_stub ${(q)key} ${(q)script_path} \"\$@\"; }"
      done
    } >| "$tmp_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }

    chmod 600 "$tmp_file" 2>/dev/null || :

    mv -f "$tmp_file" "$out_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }
    trap - EXIT INT TERM
  }

  # ----- Cache invalidation ------------------------------------------------- #
  local regen=0
  if [[ ! -f "$cache_file" ]]; then
    regen=1
  else
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$cache_file" || regen=1
    elif [[ ! -O "$cache_file" || -L "$cache_file" ]]; then
      regen=1
    fi

    local first_line
    read -r first_line < "$cache_file" 2>/dev/null
    [[ "$first_line" == "$cache_header" ]] || regen=1

    if zmodload -F zsh/stat b:zstat 2>/dev/null; then
      local -a stat_buf
      zstat -A stat_buf +mtime -- "$cache_file" 2>/dev/null || regen=1
      local cache_mtime="${stat_buf[1]:-0}"
      if (( ! regen )); then
        local sf
        for sf in "${scan_files[@]}"; do
          zstat -A stat_buf +mtime -- "$sf" 2>/dev/null || { regen=1; break; }
          if (( stat_buf[1] > cache_mtime )); then
            regen=1
            break
          fi
        done
      fi
    else
      regen=1
    fi
  fi

  # ----- Regenerate if needed ----------------------------------------------- #
  if (( regen )); then
    if ! mkdir -p "$cache_dir" 2>/dev/null; then
      print -u2 "${msg_prefix}: warning: cannot create cache directory: $cache_dir"
      return 1
    fi
    _lazy_core_build_cache "$cache_file" "${scan_files[@]}"
  fi

  # ----- Source cache with security check ----------------------------------- #
  if [[ -r "$cache_file" ]]; then
    local cache_safe=false
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$cache_file" && cache_safe=true
    elif [[ -O "$cache_file" && ! -L "$cache_file" ]]; then
      cache_safe=true
    fi

    if $cache_safe; then
      source "$cache_file"
    else
      print -u2 "${msg_prefix}: warning: skipping insecure cache file: $cache_file"
    fi
  fi

  unfunction _lazy_core_build_cache 2>/dev/null
}

# ============================================================================ #
# # End of 94-lazy-loader-core.zsh
