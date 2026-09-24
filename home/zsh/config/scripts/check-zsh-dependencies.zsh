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
#   ZSH_DOTFILES_ROOT         Checkout root for an explicit manifest update.
#   ZSH_DEPENDENCY_REGISTRY  TSV registry path override.
#   ZSH_DEPENDENCY_BREWFILE  Generated Brewfile path override.
#   ZSH_DEPENDENCY_ARCHFILE  Generated Arch package list path override.
#   ZSH_DEPENDENCY_TMPDIR    Parent for private temporary validation data.
#   ZSH_DEPENDENCY_OWNER     Install-hint owner: nix, homebrew, or arch.
# ============================================================================ #

emulate -L zsh
setopt localoptions no_aliases pipefail

typeset dependency_script_dir="${0:A:h}"
typeset dependency_config_dir="${dependency_script_dir:h}"
typeset dependency_zsh_root="${dependency_config_dir:h}"
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

# A deployed generation is read-only. Keep ordinary checks generation-local,
# but route the explicitly mutating sync workflow to the checkout. Tests and
# callers with exact path overrides retain full control of their fixture paths.
if (( dependency_sync_manifests )) &&
    [[ "$dependency_zsh_root" == /nix/store/* ]] &&
    [[ -z "${ZSH_DEPENDENCY_REGISTRY:-}" &&
       -z "${ZSH_DEPENDENCY_BREWFILE:-}" &&
       -z "${ZSH_DEPENDENCY_ARCHFILE:-}" ]]; then
  typeset dependency_checkout_root="${ZSH_DOTFILES_ROOT:-$HOME/Dotfiles}"
  typeset dependency_checkout_zsh="$dependency_checkout_root/home/zsh"
  if [[ ! -d "$dependency_checkout_zsh" ||
        ! -w "$dependency_checkout_zsh" ]]; then
    print -u2 \
      "zshdeps: writable checkout not found: $dependency_checkout_zsh"
    print -u2 \
      "zshdeps: set ZSH_DOTFILES_ROOT or run the repository script directly"
    exit 1
  fi
  dependency_zsh_root="$dependency_checkout_zsh"
  dependency_registry="$dependency_zsh_root/packages/zsh-dependencies.tsv"
  dependency_brewfile="$dependency_zsh_root/Brewfile"
  dependency_archfile="$dependency_zsh_root/packages/arch-zsh.txt"
fi

[[ -r "$dependency_registry" ]] || {
  _zsh_ui_log error "Dependency registry not found: $dependency_registry"
  exit 1
}

typeset -a dependency_rows=()
typeset -a dependency_brew_packages=()
typeset -a dependency_arch_packages=()
typeset -gi dependency_registry_errors=0
typeset level feature command_spec brew_package arch_package nix_package
typeset description
typeset line
typeset -a fields=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  fields=("${(@ps:\t:)line}")
  if (( ${#fields[@]} != 7 )); then
    _zsh_ui_log error "Malformed registry row: $line"
    (( dependency_registry_errors++ ))
    continue
  fi
  level="$fields[1]"
  feature="$fields[2]"
  command_spec="$fields[3]"
  brew_package="$fields[4]"
  arch_package="$fields[5]"
  nix_package="$fields[6]"
  description="$fields[7]"
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
    print -r -- "# Standalone Homebrew bootstrap; nix-darwin uses darwin/homebrew.nix."
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
typeset dependency_tmp_parent="${ZSH_DEPENDENCY_TMPDIR:-${TMPDIR:-/tmp}}"
[[ -d "$dependency_tmp_parent" && -w "$dependency_tmp_parent" ]] || {
  print -u2 "zshdeps: temporary directory is not writable: $dependency_tmp_parent"
  exit 1
}
dependency_tmp_root="$(mktemp -d "$dependency_tmp_parent/zshdeps.XXXXXX")" ||
  exit 1
trap '
  command rm -rf -- "$dependency_tmp_root"
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

typeset -gi dependency_checked=0
typeset -gi dependency_available=0
typeset -gi dependency_missing_required=0
typeset -gi dependency_missing_nonrequired=0
typeset -gi dependency_strict_failures=0
typeset -a alternatives=()
typeset -A dependency_level_rows=()
typeset -A dependency_level_found=()
typeset -A dependency_level_total=()
typeset command_name resolved_command package_hint
typeset dependency_kernel="$(uname -s)"

# A configuration deployed from the store belongs to a flake-managed host,
# where the registry's nix column names the owner; elsewhere the platform
# package manager does. ZSH_DEPENDENCY_OWNER=nix|homebrew|arch overrides it.
typeset dependency_owner="${ZSH_DEPENDENCY_OWNER:-}"
if [[ -z "$dependency_owner" ]]; then
  if [[ "$dependency_script_dir" == /nix/store/* ]]; then
    dependency_owner="nix"
  elif [[ "$dependency_kernel" == Darwin ]]; then
    dependency_owner="homebrew"
  else
    dependency_owner="arch"
  fi
fi
[[ "$dependency_owner" == (nix|homebrew|arch) ]] || {
  print -u2 "zshdeps: ZSH_DEPENDENCY_OWNER must be nix, homebrew, or arch"
  exit 2
}

# Collect one table row per dependency first, so each level renders as a
# single table with its missing entries in place rather than as warnings
# interleaved with the listing.
for line in "${dependency_rows[@]}"; do
  fields=("${(@ps:\t:)line}")
  level="$fields[1]"
  feature="$fields[2]"
  command_spec="$fields[3]"
  brew_package="$fields[4]"
  arch_package="$fields[5]"
  nix_package="$fields[6]"
  description="$fields[7]"
  [[ "$dependency_scope" == required && "$level" != required ]] && continue

  alternatives=("${(@s:|:)command_spec}")
  resolved_command=""
  for command_name in "${alternatives[@]}"; do
    if (( $+commands[$command_name] )); then
      resolved_command="$command_name"
      break
    fi
  done

  (( dependency_checked++ ))
  (( dependency_level_total[$level]++ ))
  if [[ -n "$resolved_command" ]]; then
    (( dependency_available++ ))
    (( dependency_level_found[$level]++ ))
    dependency_level_rows[$level]+="ok"$'\t'"$command_spec"$'\t'"$feature"
    dependency_level_rows[$level]+=$'\t'"$description"$'\n'
    continue
  fi

  package_hint="-"
  if [[ "$dependency_owner" == nix && "$nix_package" != - ]]; then
    package_hint="Home Manager package $nix_package (switch to install)"
  elif [[ "$dependency_owner" == arch ||
        ( "$dependency_owner" == nix && "$dependency_kernel" != Darwin ) ]]; then
    [[ "$arch_package" == - ]] || package_hint="pacman $arch_package"
    [[ "$arch_package" == aur:* ]] && package_hint="AUR ${arch_package#aur:}"
  else
    [[ "$brew_package" == - ]] || package_hint="brew $brew_package"
  fi
  [[ "$package_hint" == - ]] && package_hint="platform/system package"

  if [[ "$level" == required ]]; then
    (( dependency_missing_required++ ))
  else
    (( dependency_missing_nonrequired++ ))
  fi
  if [[ "$dependency_strict" == all || "$level" == required ]]; then
    (( dependency_strict_failures++ ))
    # Quiet runs print nothing else, so a failing entry still has to be named.
    (( dependency_quiet )) && _zsh_ui_log warn \
      "Missing $command_spec ($feature; install: $package_hint)."
  fi
  dependency_level_rows[$level]+="missing"$'\t'"$command_spec"$'\t'"$feature"
  dependency_level_rows[$level]+=$'\t'"install: $package_hint"$'\n'
done

if (( ! dependency_quiet )); then
  _zsh_ui_heading \
    "Zsh dependencies" \
    "Required platform · recommended experience · optional features"
  for level in required recommended optional; do
    [[ -n "${dependency_level_rows[$level]-}" ]] || continue
    print -r -- ""
    _zsh_ui_section \
      "${(C)level} · ${dependency_level_found[$level]:-0}/${dependency_level_total[$level]}"
    _zsh_ui_table --status 1 $'Status\tCommand\tFeature\tPurpose' \
      "${(@f)${dependency_level_rows[$level]%$'\n'}}"
  done
  print -r -- ""
fi

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
