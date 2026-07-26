#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ HOMEBREW DISK USAGE REPORT ++++++++++++++++++++++++ #
# ============================================================================ #
# Internal implementation behind the thin `brew_stats` wrapper in
# functions/package-management.zsh, kept separate so the package-management
# catalog stays free of this file's deep validation and measurement logic.
#
# Formula/cask inventories are resolved to canonical, non-symlink paths and
# re-checked after measurement, so a report never mixes package lists from two
# different moments. Cask artifacts outside the Caskroom (e.g. an app in
# /Applications) are measured only through roots read from a jq-validated
# `.metadata/config.json`, so an app bundle's internal symlink cycles can
# never be followed.
#
# Entry point: _brew_stats_main (see its shdoc block for the option surface).
# ============================================================================ #

# -----------------------------------------------------------------------------
# _brew_stats_fail
# @internal
# @description Prints a brew_stats diagnostic to stderr and returns a status.
# Callers rely on `err_return` to unwind to _brew_stats_main immediately.
# @arg $1 string Diagnostic message appended after "brew_stats: ".
# @arg $2 integer Optional exit status; defaults to 1.
# @exitcode 1 Default status, or the status given in $2.
# -----------------------------------------------------------------------------
_brew_stats_fail() {
  print -u2 "brew_stats: $1"
  return "${2:-1}"
}

# -----------------------------------------------------------------------------
# _brew_stats_human_kb
# @internal
# @description Formats an allocated kilobyte count as a human-readable size
# (KB-PB).
# @arg $1 integer Size in kilobytes.
# @set REPLY string The formatted size, e.g. "3.4 GB".
# -----------------------------------------------------------------------------
_brew_stats_human_kb() {
  local -a units=(KB MB GB TB PB)
  local -i index=1
  local value="${1:-0}"
  while (( value >= 1024.0 && index < ${#units[@]} )); do
    value=$(( value / 1024.0 ))
    index=$(( index + 1 ))
  done
  printf -v REPLY '%.1f %s' "$value" "${units[$index]}"
}

# -----------------------------------------------------------------------------
# _brew_stats_du_kb
# @internal
# @description Measures one path's allocated size without following symlinks.
# @arg $1 path Directory or file to measure.
# @set REPLY string The measured size in kilobytes.
# @exitcode 1 If `du` fails or its output is not a plain integer.
# -----------------------------------------------------------------------------
_brew_stats_du_kb() {
  local output
  output="$(command du -sk -- "$1")"
  REPLY="${output%%[[:space:]]*}"
  [[ "$REPLY" == <-> ]]
}

# -----------------------------------------------------------------------------
# _brew_stats_inventory
# @internal
# @description Takes a validated formula or cask inventory snapshot, resolving
# every entry to a canonical path rooted under the Cellar/Caskroom and
# rejecting anything that escapes it.
# @arg $1 string Inventory kind: formula or cask.
# @set REPLY string Canonical inventory root, empty for an empty inventory.
# @set reply array Original `brew list` snapshot (for _brew_stats_recheck)
# followed by canonical package directories.
# @exitcode 1 If the inventory cannot be read, an entry's directory is missing
# or escapes its root, or the root itself is invalid.
# -----------------------------------------------------------------------------
_brew_stats_inventory() {
  local kind="$1" noun root_option root_label
  if [[ "$kind" == formula ]]; then
    noun="formula"; root_option="--cellar"; root_label="Cellar"
  else
    noun="cask"; root_option="--caskroom"; root_label="Caskroom"
  fi

  local inventory
  inventory="$(command brew list "--$kind")" ||
    _brew_stats_fail "could not read the installed $noun inventory."
  reply=("$inventory")
  REPLY=""
  [[ -n "$inventory" ]] || return 0

  local root
  root="$(command brew "$root_option")" && [[ -d "$root" ]] ||
    _brew_stats_fail "could not resolve the Homebrew $root_label."
  [[ "$root" != *[[:cntrl:]]* ]] ||
    _brew_stats_fail "invalid Homebrew $root_label path."
  root="${root:A}"
  [[ "$root" != / && "$root" != *[[:cntrl:]]* ]] ||
    _brew_stats_fail "refusing to use / as the Homebrew $root_label."

  local name package_dir
  local -a package_dirs=()
  local -A canonical_casks=()
  for name in "${(f)inventory}"; do
    [[ -n "$name" ]] || continue
    [[ "$name" != */* && "$name" != . && "$name" != .. &&
       "$name" != *[[:cntrl:]]* ]] ||
      _brew_stats_fail "invalid $noun name in inventory."

    package_dir="$root/$name"
    if [[ "$kind" == formula ]]; then
      [[ -d "$package_dir" ]] ||
        _brew_stats_fail "formula directory is missing: $name"
    else
      [[ -e "$package_dir" ]] ||
        _brew_stats_fail "cask directory is missing: $name"
    fi

    package_dir="${package_dir:A}"
    [[ "$kind" != cask || -d "$package_dir" ]] ||
      _brew_stats_fail "invalid cask directory: $name"
    [[ "$package_dir" == "$root"/* ]] ||
      _brew_stats_fail "$noun escapes the $root_label: $name"
    if [[ "$kind" == cask ]]; then
      canonical_casks[$package_dir]=1
    else
      package_dirs+=("$package_dir")
    fi
  done

  [[ "$kind" == cask ]] && package_dirs=("${(k)canonical_casks[@]}")
  REPLY="$root"
  reply+=("${package_dirs[@]}")
}

# -----------------------------------------------------------------------------
# _brew_stats_cask_artifact_roots
# @internal
# @description Reads absolute artifact install roots from a cask's
# `.metadata/config.json`, rejecting anything outside a securely owned file.
# @arg $1 path Canonical cask directory.
# @set reply array Validated absolute artifact roots; empty if none.
# @exitcode 1 If the config file is insecure, jq is unavailable, or the config
# lists no artifact root.
# -----------------------------------------------------------------------------
_brew_stats_cask_artifact_roots() {
  local config_file="$1/.metadata/config.json" output artifact_root
  _zsh_is_secure_file "$config_file"
  (( $+commands[jq] ))
  output="$(command jq -er \
    '((.default // {}) + (.explicit // {}))[] |
     select(type == "string")' "$config_file")"

  reply=()
  for artifact_root in "${(f)output}"; do
    [[ "$artifact_root" == /* &&
       "$artifact_root" != *[[:cntrl:]]* ]] || continue
    artifact_root="${artifact_root:A}"
    [[ "$artifact_root" != / &&
       "$artifact_root" != *[[:cntrl:]]* ]] &&
      reply+=("$artifact_root")
  done
  (( ${#reply[@]} ))
}

# -----------------------------------------------------------------------------
# _brew_stats_cask_kb
# @internal
# @description Measures a cask directory plus the outermost validated
# artifact links it points to, without recursively following symlinks (an
# installed app bundle's own internal links can cycle).
# @arg $1 path Cask directory (Caskroom entry).
# @set REPLY string Total measured size in kilobytes.
# @exitcode 1 If any measurement fails or an artifact link points outside its
# cask's validated roots.
# -----------------------------------------------------------------------------
_brew_stats_cask_kb() {
  local package_dir="${1:A}"
  _brew_stats_du_kb "$package_dir"
  local -i total_kb=$REPLY

  # Caskroom links point at installed artifacts. Follow only their outermost
  # targets: du -L can recurse into cycles inside application bundles.
  local -A external_targets=()
  local -a artifact_roots=() reply=()
  local link target artifact_root roots_loaded=false allowed
  for link in "$package_dir"/**/*(@DN); do
    [[ -e "$link" ]]
    target="${link:A}"
    [[ "$target" == "$package_dir" ||
       "$target" == "$package_dir"/* ]] && continue

    if [[ "$roots_loaded" == false ]]; then
      _brew_stats_cask_artifact_roots "$package_dir"
      artifact_roots=("${reply[@]}")
      roots_loaded=true
    fi
    allowed=false
    for artifact_root in "${artifact_roots[@]}"; do
      if [[ "$target" == "$artifact_root"/* ]]; then
        allowed=true
        break
      fi
    done
    [[ "$allowed" == true ]]
    external_targets[$target]=1
  done

  # Walking ancestors avoids an O(n²) comparison between artifact targets.
  local candidate ancestor nested
  local -a measured_targets=()
  for candidate in "${(k)external_targets[@]}"; do
    nested=false
    ancestor="${candidate:h}"
    while [[ "$ancestor" != / && "$ancestor" != . ]]; do
      if (( ${+external_targets[$ancestor]} )); then
        nested=true
        break
      fi
      ancestor="${ancestor:h}"
    done
    [[ "$nested" == true ]] || measured_targets+=("$candidate")
  done

  for target in "${measured_targets[@]}"; do
    _brew_stats_du_kb "$target"
    total_kb=$(( total_kb + REPLY ))
  done
  REPLY="$total_kb"
}

# -----------------------------------------------------------------------------
# _brew_stats_formula_records
# @internal
# @description Measures every formula directory in one `du` process and
# returns one stable name/type/size record per package.
# @arg $1 path Canonical Cellar root.
# @arg $@ path Canonical formula directories to measure.
# @set REPLY string Total measured size in kilobytes.
# @set reply array One "name\tformula\tkb" record per directory, in argument
# order.
# @exitcode 1 If `du` fails or its output is incomplete or unparsable.
# -----------------------------------------------------------------------------
_brew_stats_formula_records() {
  local root="$1"
  shift
  reply=()
  REPLY=0
  (( $# )) || return 0

  local output package_dir
  if ! output="$(command du -sk -- "$@")"; then
    for package_dir in "$@"; do
      _brew_stats_du_kb "$package_dir" ||
        _brew_stats_fail "could not measure formula: ${package_dir:t}"
    done
    _brew_stats_fail "could not measure the formula inventory."
  fi

  local -a lines=("${(f)output}")
  (( ${#lines[@]} == $# )) ||
    _brew_stats_fail "formula size output is incomplete."
  local line kb measured_path
  local -A sizes=()
  for line in "${lines[@]}"; do
    kb="${line%%[[:space:]]*}"
    measured_path="${line#*$'\t'}"
    [[ "$kb" == <-> && "$measured_path" != "$line" &&
       "$measured_path" == "$root"/* ]] ||
      _brew_stats_fail "formula size output is invalid."
    sizes[$measured_path]="$kb"
  done

  local -i total_kb=0
  for package_dir in "$@"; do
    kb="${sizes[$package_dir]-}"
    [[ "$kb" == <-> ]] ||
      _brew_stats_fail "formula size is missing: ${package_dir:t}"
    reply+=("${package_dir:t}"$'\tformula\t'"$kb")
    total_kb=$(( total_kb + kb ))
  done
  REPLY="$total_kb"
}

# -----------------------------------------------------------------------------
# _brew_stats_recheck
# @internal
# @description Rejects a report whose formula or cask inventory changed
# between the initial snapshot and now.
# @arg $1 string Inventory kind: formula or cask.
# @arg $2 string Snapshot to compare against the current `brew list` output.
# @exitcode 1 If the inventory cannot be re-read or no longer matches the
# snapshot.
# -----------------------------------------------------------------------------
_brew_stats_recheck() {
  local kind="$1" expected="$2" current
  current="$(command brew list "--$kind")" ||
    _brew_stats_fail "could not re-read the $kind inventory."
  [[ "$current" == "$expected" ]] ||
    _brew_stats_fail "installed $kind inventory changed; retry the report."
}

# -----------------------------------------------------------------------------
# _brew_stats_cache_summary
# @internal
# @description Validates the Homebrew cache path and formats its summary line.
# @set REPLY string Sanitized "Cache:    <size> (<path>)" summary line.
# @exitcode 1 If the cache path is invalid, a broken symlink, not a directory,
# or cannot be measured.
# -----------------------------------------------------------------------------
_brew_stats_cache_summary() {
  local cache_dir cache_kb
  cache_dir="$(command brew --cache)" ||
    _brew_stats_fail "could not resolve the Homebrew cache."
  [[ -n "$cache_dir" && "$cache_dir" == /* ]] ||
    _brew_stats_fail "invalid Homebrew cache path."
  [[ ! -L "$cache_dir" || -e "$cache_dir" ]] ||
    _brew_stats_fail "Homebrew cache path is a broken symlink."
  cache_dir="${cache_dir:A}"
  [[ "$cache_dir" != / ]] ||
    _brew_stats_fail "refusing to use / as the Homebrew cache."
  [[ ! -e "$cache_dir" || -d "$cache_dir" ]] ||
    _brew_stats_fail "Homebrew cache path is not a directory."

  if [[ -d "$cache_dir" ]]; then
    _brew_stats_du_kb "$cache_dir" ||
      _brew_stats_fail "could not measure the Homebrew cache."
    cache_kb="$REPLY"
  else
    cache_kb=0
  fi
  _brew_stats_human_kb "$cache_kb"
  local cache_human="$REPLY"
  _zsh_ui_sanitize_text "$cache_dir"
  REPLY="Cache:    $cache_human ($REPLY)"
}

# -----------------------------------------------------------------------------
# _brew_stats_sort_records
# @internal
# @description Sorts name/type/kilobyte records by size (descending) or name
# (ascending) and applies an optional row limit.
# @arg $1 string Sort key: size or name.
# @arg $2 integer Row limit; 0 keeps every record.
# @arg $@ string Records to sort, each "name\ttype\tkb".
# @set reply array Sorted, and possibly row-limited, records.
# -----------------------------------------------------------------------------
_brew_stats_sort_records() {
  local sort_key="$1"
  local -i top="$2"
  shift 2
  reply=("$@")
  if [[ "$sort_key" == name ]]; then
    reply=("${(o)reply[@]}")
  else
    local record
    local -a fields keyed=()
    for record in "${reply[@]}"; do
      fields=("${(@ps:\t:)record}")
      keyed+=("${fields[3]}"$'\t'"$record")
    done
    keyed=("${(On)keyed[@]}")
    reply=("${(@)keyed#*$'\t'}")
  fi
  (( top > 0 && top < ${#reply[@]} )) &&
    reply=("${(@)reply[1,top]}")
  return 0
}

# -----------------------------------------------------------------------------
# _brew_stats_main
# @internal
# @description Builds and renders a consistent report of installed Homebrew
# package counts and on-disk sizes. Called by the public brew_stats wrapper
# in functions/package-management.zsh; see its shdoc block for the supported
# option surface.
# @arg $@ string Optional flags; see --help.
# @option -f | --formula Show only formulae.
# @option -c | --cask Show only casks.
# @option --top <n> Limit the table to the n largest (or first) entries.
# @option --sort size|name Sort order; defaults to size.
# @option -q | --quiet Print only the table, no heading or summary card.
# @option -h | --help Show usage information.
# @exitcode 1 If Homebrew, an inventory, a measurement, the cache, or
# rendering fails, or if the installed inventory changes while the report is
# built.
# @exitcode 2 If command-line arguments are invalid.
# -----------------------------------------------------------------------------
_brew_stats_main() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail extendedglob err_return

  (( $+commands[brew] )) || _brew_stats_fail "Homebrew is not installed."
  local scope="all" sort_key="size"
  local -i quiet=0 top=0
  while (( $# )); do
    case "$1" in
      -f|--formula)
        [[ "$scope" != cask ]] ||
          _brew_stats_fail "--formula and --cask are mutually exclusive." 2
        scope="formula"
        ;;
      -c|--cask)
        [[ "$scope" != formula ]] ||
          _brew_stats_fail "--formula and --cask are mutually exclusive." 2
        scope="cask"
        ;;
      --top)
        [[ "${2-}" == <1-> ]] ||
          _brew_stats_fail "--top requires a positive integer." 2
        top=$2
        shift
        ;;
      --sort)
        [[ "${2-}" == size || "${2-}" == name ]] ||
          _brew_stats_fail "--sort requires 'size' or 'name'." 2
        sort_key=$2
        shift
        ;;
      -q|--quiet) quiet=1 ;;
      -h|--help)
        print -r -- \
'Usage: brew_stats [-f|--formula] [-c|--cask] [--top N] [--sort size|name] [-q|--quiet]

Reports the number and on-disk size of installed Homebrew packages.

Formula sizes include all installed Cellar versions. Cask sizes include the
Caskroom entry and linked artifacts; files placed by .pkg installers cannot
be attributed reliably and are not included.

Safe linked-artifact measurement requires jq when installed casks use links.

  -f, --formula   Show only formulae (skip casks).
  -c, --cask      Show only casks (skip formulae).
  --top N         Limit the table to the N largest (or first) entries.
  --sort size|name  Sort order; defaults to size, largest first.
  -q, --quiet     Print only the table; suppress the heading and summary.'
        return 0
        ;;
      *) _brew_stats_fail "unknown argument: $1" 2 ;;
    esac
    shift
  done

  _zsh_ui_load
  if (( ! quiet )) && ! _zsh_ui_resolve_mode; then
    _brew_stats_fail "could not render the report."
    return
  fi

  local formula_root="" formula_snapshot="" cask_snapshot=""
  local -a formula_dirs=() cask_dirs=() reply=()
  if [[ "$scope" != cask ]]; then
    _brew_stats_inventory formula
    formula_root="$REPLY"
    formula_snapshot="${reply[1]-}"
    formula_dirs=("${(@)reply[2,-1]}")
  fi
  if [[ "$scope" != formula ]]; then
    _brew_stats_inventory cask
    cask_snapshot="${reply[1]-}"
    cask_dirs=("${(@)reply[2,-1]}")
  fi

  if (( ${#formula_dirs[@]} + ${#cask_dirs[@]} == 0 )); then
    if (( quiet )); then
      _brew_stats_fail "no installed packages found." 0
    else
      _zsh_ui_log warn "No installed Homebrew packages found." ||
        _brew_stats_fail "could not render the report."
    fi
    return 0
  fi

  local -a records=()
  local -i formula_kb=0 cask_kb=0
  if (( ${#formula_dirs[@]} )); then
    _brew_stats_formula_records "$formula_root" "${formula_dirs[@]}"
    formula_kb=$REPLY
    records+=("${reply[@]}")
  fi
  if (( ${#cask_dirs[@]} )); then
    local package_dir
    for package_dir in "${cask_dirs[@]}"; do
      _brew_stats_cask_kb "$package_dir" ||
        _brew_stats_fail "could not measure cask: ${package_dir:t}"
      records+=("${package_dir:t}"$'\tcask\t'"$REPLY")
      cask_kb=$(( cask_kb + REPLY ))
    done
  fi

  [[ "$scope" == cask ]] ||
    _brew_stats_recheck formula "$formula_snapshot"
  [[ "$scope" == formula ]] ||
    _brew_stats_recheck cask "$cask_snapshot"
  _brew_stats_sort_records "$sort_key" "$top" "${records[@]}"

  local record
  local -a fields rows=()
  for record in "${reply[@]}"; do
    fields=("${(@ps:\t:)record}")
    _brew_stats_human_kb "${fields[3]}"
    rows+=("${fields[1]}"$'\t'"${(C)fields[2]}"$'\t'"$REPLY")
  done

  if (( quiet )); then
    ZSH_UI_STYLE=plain \
      _zsh_ui_table $'Package\tType\tSize' "${rows[@]}" ||
        _brew_stats_fail "could not render the report."
    return 0
  fi

  local -i formula_count=${#formula_dirs[@]}
  local -i cask_count=${#cask_dirs[@]}
  local -i total_count=$(( formula_count + cask_count ))
  local -i total_kb=$(( formula_kb + cask_kb ))
  local -a summary=()
  if [[ "$scope" != cask ]]; then
    _brew_stats_human_kb "$formula_kb"
    summary+=("Formulae: $formula_count ($REPLY)")
  fi
  if [[ "$scope" != formula ]]; then
    _brew_stats_human_kb "$cask_kb"
    summary+=("Casks:    $cask_count ($REPLY)")
  fi
  _brew_stats_human_kb "$total_kb"
  summary+=("Total:    $total_count packages ($REPLY)")
  _brew_stats_cache_summary
  summary+=("$REPLY")

  _zsh_ui_table $'Package\tType\tSize' "${rows[@]}" ||
    _brew_stats_fail "could not render the report."
  print -r -- ""
  _zsh_ui_card "Homebrew disk usage" "${summary[@]}" ||
    _brew_stats_fail "could not render the report."
}

# ============================================================================ #
# End of brew-stats.zsh
