#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ SHDOC COMPLETION CACHE GENERATOR +++++++++++++++++++++ #
# ============================================================================ #
# Converts public shdoc @arg, @option, and @noargs metadata into Zsh
# `_arguments` specifications. The generated file contains data only; runtime
# registration is owned by lib/85-completions.zsh.
#
# Usage: generate-zsh-completions.zsh [config-dir]
#   config-dir  Root to scan; default: ZSH_CONFIG_DIR or this file's parent.
# ============================================================================ #

emulate -L zsh
setopt localoptions no_aliases pipefail extendedglob

if (( $# > 1 )); then
  print -u2 "Usage: generate-zsh-completions.zsh [config-dir]"
  exit 2
fi

typeset config_dir="${1:-${ZSH_CONFIG_DIR:-${0:A:h:h}}}"
typeset indexer="$config_dir/scripts/zfuncs-index.awk"
typeset separator=$'\x1f'
typeset item_separator=$'\x1e'
typeset field_separator=$'\x1d'
typeset spec_separator=$'\x1f'
typeset -a source_files

[[ -r "$indexer" ]] || {
  print -u2 "completion generator: indexer not found: $indexer"
  exit 1
}

source_files=(
  "$config_dir"/functions/*.zsh(N.)
  "$config_dir"/lib/*.zsh(N.)
  "$config_dir"/scripts/**/*.sh(N.)
  "$config_dir"/scripts/**/*.zsh(N.)
)
(( ${#source_files[@]} )) || {
  print -u2 "completion generator: no shell sources found below $config_dir"
  exit 1
}

typeset metadata
metadata="$(
  LC_ALL=C command awk \
    -v sep="$separator" \
    -v completion_item_sep="$item_separator" \
    -v completion_field_sep="$field_separator" \
    -v output="completions" \
    -f "$indexer" \
    "${source_files[@]}"
)" || exit 1

typeset -A specs_by_name=()
typeset -A seen_specs=()
typeset name summary kind label value_type description
typeset spec action message lower_description option_description
typeset position alias group dedupe_key
typeset -a option_aliases

while IFS="$separator" read -r \
    name summary kind label value_type description; do
  [[ "$name" == [A-Za-z][A-Za-z0-9_-]# ]] || continue
  spec=""

  case "$kind" in
    noargs)
      spec="1:no additional arguments"
      ;;
    arg)
      message="${description:-argument}"
      message="${message//:/ -}"
      message="${message//\[/\(}"
      message="${message//\]/\)}"
      action=""
      lower_description="${(L)description}"
      case "${(L)value_type}" in
        path)
          if [[ "$lower_description" == *director* ]]; then
            action="_directories"
          else
            action="_files"
          fi
          ;;
        boolean)
          action="(true false)"
          ;;
        command)
          action="_command_names"
          ;;
        integer)
          action='_guard "[0-9]#" integer'
          ;;
      esac

      if [[ "$label" == '$@' ]]; then
        position="*"
      elif [[ "$label" == \$<-> ]]; then
        position="${label#\$}"
      else
        continue
      fi
      if [[ -n "$action" ]]; then
        spec="${position}:${message}:${action}"
      else
        spec="${position}:${message}"
      fi
      ;;
    option)
      option_aliases=("${(@s:|:)label}")
      (( ${#option_aliases[@]} )) || continue
      option_description="${description:-option}"
      option_description="${option_description//\[/\(}"
      option_description="${option_description//\]/\)}"
      group="${(j: :)option_aliases}"
      for alias in "${option_aliases[@]}"; do
        if (( ${#option_aliases[@]} > 1 )); then
          spec="(${group})${alias}[${option_description}]"
        else
          spec="${alias}[${option_description}]"
        fi
        dedupe_key="${name}${separator}${spec}"
        [[ -n "${seen_specs[$dedupe_key]-}" ]] && continue
        seen_specs[$dedupe_key]=1
        if [[ -n "${specs_by_name[$name]-}" ]]; then
          specs_by_name[$name]+="${spec_separator}${spec}"
        else
          specs_by_name[$name]="$spec"
        fi
      done
      continue
      ;;
    *)
      continue
      ;;
  esac

  dedupe_key="${name}${separator}${spec}"
  [[ -n "${seen_specs[$dedupe_key]-}" ]] && continue
  seen_specs[$dedupe_key]=1
  if [[ -n "${specs_by_name[$name]-}" ]]; then
    specs_by_name[$name]+="${spec_separator}${spec}"
  else
    specs_by_name[$name]="$spec"
  fi
done < <(print -r -- "$metadata")

typeset -a command_names=("${(onk)specs_by_name[@]}")
(( ${#command_names[@]} )) || {
  print -u2 "completion generator: no standard public metadata found"
  exit 1
}

print -r -- "# Generated from shdoc metadata; do not edit."
print -r -- "typeset -gA _ZSH_CUSTOM_COMPLETION_SPECS=()"
for name in "${command_names[@]}"; do
  print -r -- \
    "_ZSH_CUSTOM_COMPLETION_SPECS[${(q)name}]="\
"${(qqqq)specs_by_name[$name]}"
done
print -r -- "typeset -ga _ZSH_CUSTOM_COMPLETION_COMMANDS=("
for name in "${command_names[@]}"; do
  print -r -- "  ${(qqq)name}"
done
print -r -- ")"

# ============================================================================ #
# End of generate-zsh-completions.zsh
