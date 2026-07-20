#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ ZSH DEPENDENCY CHECKER ++++++++++++++++++++++++++ #
# ============================================================================ #
# Reports supported shell dependencies and keeps platform manifests aligned
# with the canonical TSV registry (packages/zsh-dependencies.tsv). Invoked as
# `zshdeps` via functions/development-tools.zsh; run with --help for options.
#
# Environment:
#   ZSH_DEPENDENCY_REGISTRY  TSV registry path override.
#   ZSH_DEPENDENCY_BREWFILE  Generated Brewfile path override.
#   ZSH_DEPENDENCY_ARCHFILE  Generated Arch package list path override.
# ============================================================================ #

emulate -L zsh
setopt localoptions no_aliases pipefail

typeset dependency_script_dir="${0:A:h}"
typeset dependency_config_dir="${dependency_script_dir:h}"
typeset dependency_zsh_root="${dependency_config_dir:h:h}"
typeset dependency_registry="${ZSH_DEPENDENCY_REGISTRY:-\
$dependency_zsh_root/packages/zsh-dependencies.tsv}"
typeset dependency_brewfile="${ZSH_DEPENDENCY_BREWFILE:-\
$dependency_zsh_root/Brewfile}"
typeset dependency_archfile="${ZSH_DEPENDENCY_ARCHFILE:-\
$dependency_zsh_root/packages/arch-zsh.txt}"
typeset dependency_helpers="$dependency_script_dir/_shared-helpers.zsh"

[[ -r "$dependency_helpers" ]] || {
  print -u2 "zshdeps: shared helpers not found: $dependency_helpers"
  exit 1
}
source "$dependency_helpers" || exit 1

typeset dependency_scope="all"
typeset dependency_strict="required"
typeset -gi dependency_check_manifests=0
typeset -gi dependency_sync_manifests=0
typeset -gi dependency_quiet=0
typeset -gi dependency_scope_set=0

while (( $# )); do
  case "$1" in
    --required)
      (( dependency_scope_set )) && {
        print -u2 "zshdeps: choose only one of --required or --all"
        exit 2
      }
      dependency_scope="required"
      dependency_strict="required"
      dependency_scope_set=1
      ;;
    --all)
      (( dependency_scope_set )) && {
        print -u2 "zshdeps: choose only one of --required or --all"
        exit 2
      }
      dependency_scope="all"
      dependency_strict="all"
      dependency_scope_set=1
      ;;
    --check-manifests)
      dependency_check_manifests=1
      ;;
    --sync-manifests)
      dependency_sync_manifests=1
      ;;
    --quiet)
      dependency_quiet=1
      ;;
    -h|--help)
      print -rl -- \
        "Usage: check-zsh-dependencies.zsh [options]" \
        "" \
        "  --required         Show required dependencies only." \
        "  --all              Treat every missing dependency as an error." \
        "  --check-manifests  Verify generated package manifests." \
        "  --sync-manifests   Regenerate manifests from the TSV registry." \
        "  --quiet            Print only errors and the final summary." \
        "  -h, --help         Show this help." \
        "" \
        "Without a scope, missing required commands alone produce failure."
      exit 0
      ;;
    *)
      print -u2 "zshdeps: unknown option: $1"
      exit 2
      ;;
  esac
  shift
done

[[ -r "$dependency_registry" ]] || {
  _zsh_ui_log error "Dependency registry not found: $dependency_registry"
  exit 1
}

typeset -a dependency_rows=()
typeset -a dependency_brew_packages=()
typeset -a dependency_arch_packages=()
typeset -gi dependency_registry_errors=0
typeset level feature command_spec brew_package arch_package description
typeset line
typeset -a fields=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  fields=("${(@ps:\t:)line}")
  if (( ${#fields[@]} != 6 )); then
    _zsh_ui_log error "Malformed registry row: $line"
    (( dependency_registry_errors++ ))
    continue
  fi
  level="$fields[1]"
  feature="$fields[2]"
  command_spec="$fields[3]"
  brew_package="$fields[4]"
  arch_package="$fields[5]"
  description="$fields[6]"
  case "$level" in
    required|recommended|optional) ;;
    *)
      _zsh_ui_log error "Invalid dependency level '$level'."
      (( dependency_registry_errors++ ))
      continue
      ;;
  esac
  dependency_rows+=("$line")
  [[ "$brew_package" == - ]] || dependency_brew_packages+=("$brew_package")
  [[ "$arch_package" == - || "$arch_package" == aur:* ]] ||
    dependency_arch_packages+=("$arch_package")
done < "$dependency_registry"

(( dependency_registry_errors == 0 && ${#dependency_rows[@]} > 0 )) || exit 1

_dependency_render_brewfile() {
  local output_file="$1" package
  {
    print -r -- "# Generated from packages/zsh-dependencies.tsv."
    print -r -- "# Regenerate with: zshdeps --sync-manifests"
    print -r -- "# Do not edit manually."
    print -r -- ""
    for package in "${(ou)dependency_brew_packages[@]}"; do
      printf 'brew "%s"\n' "$package"
    done
  } >| "$output_file"
}

_dependency_render_archfile() {
  local output_file="$1" package
  {
    print -r -- "# Generated from zsh-dependencies.tsv."
    print -r -- "# Regenerate with: zshdeps --sync-manifests"
    print -r -- "# Official packages; see docs/zsh-dependencies.md for AUR."
    print -r -- ""
    for package in "${(ou)dependency_arch_packages[@]}"; do
      print -r -- "$package"
    done
  } >| "$output_file"
}

typeset dependency_tmp_root=""
typeset dependency_tmp_parent="$dependency_config_dir/tests/.tmp"
command mkdir -p -- "$dependency_tmp_parent" || exit 1
dependency_tmp_root="$(mktemp -d "$dependency_tmp_parent/zshdeps.XXXXXX")" ||
  exit 1
trap '
  command rm -rf -- "$dependency_tmp_root"
  command rmdir -- "$dependency_tmp_parent" 2>/dev/null
  command true
' EXIT INT TERM

typeset expected_brewfile="$dependency_tmp_root/Brewfile"
typeset expected_archfile="$dependency_tmp_root/arch-zsh.txt"
_dependency_render_brewfile "$expected_brewfile" || exit 1
_dependency_render_archfile "$expected_archfile" || exit 1

if (( dependency_sync_manifests )); then
  command mkdir -p -- "${dependency_archfile:h}" || exit 1
  typeset sync_brewfile=""
  typeset sync_archfile=""
  sync_brewfile="$(mktemp "${dependency_brewfile:h}/.Brewfile.XXXXXX")" ||
    exit 1
  sync_archfile="$(mktemp "${dependency_archfile:h}/.arch-zsh.XXXXXX")" || {
    command rm -f -- "$sync_brewfile"
    exit 1
  }
  command cp -- "$expected_brewfile" "$sync_brewfile" &&
    command cp -- "$expected_archfile" "$sync_archfile" &&
    command chmod 644 "$sync_brewfile" "$sync_archfile" &&
    command mv -f -- "$sync_brewfile" "$dependency_brewfile" &&
    command mv -f -- "$sync_archfile" "$dependency_archfile" || {
      command rm -f -- "$sync_brewfile" "$sync_archfile"
      exit 1
    }
  (( dependency_quiet )) ||
    _zsh_ui_log ok "Regenerated Homebrew and Arch dependency manifests."
fi

typeset -gi dependency_manifest_failures=0
if (( dependency_check_manifests )); then
  if ! command cmp -s -- "$expected_brewfile" "$dependency_brewfile"; then
    _zsh_ui_log error "Brewfile differs from the dependency registry."
    command diff -u -- "$dependency_brewfile" "$expected_brewfile" >&2 || true
    (( dependency_manifest_failures++ ))
  fi
  if ! command cmp -s -- "$expected_archfile" "$dependency_archfile"; then
    _zsh_ui_log error "Arch package list differs from the dependency registry."
    command diff -u -- "$dependency_archfile" "$expected_archfile" >&2 || true
    (( dependency_manifest_failures++ ))
  fi
  if (( dependency_manifest_failures == 0 && ! dependency_quiet )); then
    _zsh_ui_log ok "Dependency manifests match the registry."
  fi
fi

(( dependency_quiet )) || {
  _zsh_ui_heading \
    "Zsh dependencies" \
    "Required platform · recommended experience · optional features"
  print -r -- ""
}

typeset current_level=""
typeset -gi dependency_checked=0
typeset -gi dependency_available=0
typeset -gi dependency_missing_required=0
typeset -gi dependency_missing_nonrequired=0
typeset -gi dependency_strict_failures=0
typeset -a alternatives=()
typeset command_name resolved_command package_hint
typeset dependency_kernel="$(uname -s)"

for line in "${dependency_rows[@]}"; do
  fields=("${(@ps:\t:)line}")
  level="$fields[1]"
  feature="$fields[2]"
  command_spec="$fields[3]"
  brew_package="$fields[4]"
  arch_package="$fields[5]"
  description="$fields[6]"
  [[ "$dependency_scope" == required && "$level" != required ]] && continue

  if (( ! dependency_quiet )) && [[ "$level" != "$current_level" ]]; then
    [[ -z "$current_level" ]] || print -r -- ""
    _zsh_ui_section "${(C)level}"
    current_level="$level"
  fi

  alternatives=("${(@s:|:)command_spec}")
  resolved_command=""
  for command_name in "${alternatives[@]}"; do
    if (( $+commands[$command_name] )); then
      resolved_command="$command_name"
      break
    fi
  done

  (( dependency_checked++ ))
  if [[ -n "$resolved_command" ]]; then
    (( dependency_available++ ))
    (( dependency_quiet )) || printf '  %-4s %-18s %-14s %s\n' \
      "ok" "$command_spec" "$feature" "$description"
    continue
  fi

  if [[ "$dependency_kernel" == Darwin ]]; then
    package_hint="$brew_package"
  else
    package_hint="$arch_package"
  fi
  [[ "$package_hint" == - ]] && package_hint="platform/system package"

  if [[ "$level" == required ]]; then
    (( dependency_missing_required++ ))
  else
    (( dependency_missing_nonrequired++ ))
  fi
  if [[ "$dependency_strict" == all || "$level" == required ]]; then
    (( dependency_strict_failures++ ))
  fi
  if (( ! dependency_quiet )) ||
      [[ "$dependency_strict" == all || "$level" == required ]]; then
    _zsh_ui_log warn \
      "Missing $command_spec ($feature; package: $package_hint)."
  fi
done

(( dependency_quiet )) || print -r -- ""
_zsh_ui_rule "=" 80
if (( dependency_strict_failures == 0 &&
      dependency_manifest_failures == 0 )); then
  _zsh_ui_log ok \
    "$dependency_available/$dependency_checked available; contract satisfied."
  (( dependency_missing_nonrequired == 0 )) ||
    _zsh_ui_log info \
      "$dependency_missing_nonrequired non-required feature(s) unavailable."
  exit 0
fi

_zsh_ui_log error \
  "$dependency_strict_failures dependency failure(s); "\
"$dependency_manifest_failures manifest failure(s)."
exit 1

# ============================================================================ #
# End of check-zsh-dependencies.zsh
