#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# +++++++++++++++++++++++++ PACKAGE OWNERSHIP AUDIT ++++++++++++++++++++++++++ #
# ============================================================================ #
# Read-only audit of the declared nix-darwin Homebrew inventory against the
# live installation. Reports:
#
#  - declared formulae, casks, and taps that are not installed
#  - manually requested formulae, casks, and taps that are undeclared
#  - reverse dependencies that may prevent removing undeclared formulae
#  - commands supplied by both Nix and Homebrew
#  - unexpected cases where Homebrew precedes Nix in PATH
#
# Intentional command-overlap policy lives in:
#   home/package-ownership-allowlist.tsv
#
# Usage:
#   scripts/audit-package-ownership.sh [--verbose]
#
# Set NIX_DARWIN_CONFIGURATION to audit a differently named Darwin output.
# Use --verbose to print every benign case where Nix already wins.
# The command never installs, uninstalls, upgrades, taps, or untaps anything.
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
policy_file="$repo_root/home/package-ownership-allowlist.tsv"
darwin_configuration="${NIX_DARWIN_CONFIGURATION:-LCSMacBook-Pro}"
home_dir="${HOME:-}"
issues=0
inventory_drift=0
path_conflicts=0
policy_issues=0
overlaps=0
other_winners=0
verbose=0

# +++++++++++++++++++++++++ USAGE & ARGUMENT PARSING +++++++++++++++++++++++++ #

usage() {
  cat <<'EOF'
Usage: scripts/audit-package-ownership.sh [--verbose]

Read-only audit of the declared nix-darwin Homebrew inventory and the live
installation. Reports:

  - declared formulae, casks, and taps that are not installed;
  - manually requested formulae, casks, and taps that are undeclared;
  - reverse dependencies that may prevent removing undeclared formulae;
  - commands supplied by both Nix and Homebrew;
  - unexpected cases where Homebrew precedes Nix in PATH.

Intentional command overlap policy lives in:
  home/package-ownership-allowlist.tsv

Set NIX_DARWIN_CONFIGURATION to audit a differently named Darwin output.
Use --verbose to print every benign case where Nix already wins.
The command never installs, uninstalls, upgrades, taps, or untaps anything.
EOF
}

while (($#)); do
  case "$1" in
  --verbose)
    verbose=1
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

# +++++++++++++++++++++++++++ PREREQUISITE CHECKS ++++++++++++++++++++++++++++ #

if [[ ! "$darwin_configuration" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Invalid NIX_DARWIN_CONFIGURATION value: %s\n' \
    "$darwin_configuration" >&2
  exit 2
fi
if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
  printf 'Package ownership audit requires HOME to name an existing directory.\n' >&2
  exit 2
fi

for required_command in awk brew comm jq mktemp nix realpath sort tr uniq wc; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Package ownership audit requires %s.\n' "$required_command" >&2
    exit 2
  fi
done

if [[ ! -r "$policy_file" ]]; then
  printf 'Package ownership policy is missing: %s\n' "$policy_file" >&2
  exit 2
fi

if ! bash "$repo_root/scripts/check-package-ownership-policy.sh" >/dev/null; then
  exit 2
fi

# +++++++++++++++++++++++++++ WORKSPACE & CLEANUP ++++++++++++++++++++++++++++ #

if ! temp_root="$(
  mktemp -d "${TMPDIR:-/tmp}/package-ownership-audit.XXXXXX" 2>/dev/null ||
    mktemp -d "$repo_root/.package-ownership-audit.XXXXXX"
)"; then
  printf 'Unable to create a private package-audit workspace.\n' >&2
  exit 2
fi
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

flake_ref="$repo_root#darwinConfigurations.\"$darwin_configuration\".config.homebrew"
if ! brew_prefix="$(brew --prefix)"; then
  printf 'Unable to determine the Homebrew prefix.\n' >&2
  exit 2
fi
if [[ "$brew_prefix" != /* || ! -d "$brew_prefix" ]]; then
  printf 'Homebrew returned an invalid prefix: %s\n' "$brew_prefix" >&2
  exit 2
fi

# +++++++++++++++++++++++++++++ HELPER FUNCTIONS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# declared_names
# @internal
# @description Reads a unique, sorted list of declared names for one
# homebrew.<option> array (brews, casks, or taps) out of the evaluated flake
# JSON.
# @arg $1 string Homebrew option name: brews, casks, or taps.
# @arg $2 path Destination file for the sorted, unique name list.
# @exitcode 2 If the option cannot be read from the evaluated JSON.
# -----------------------------------------------------------------------------
declared_names() {
  local option="$1"
  local destination="$2"

  if ! jq -r --arg option "$option" '
    if (.[$option] | type) != "array" then
      error("homebrew option is not an array")
    else
      .[$option] | map(.name) | unique | .[]
    end
  ' \
    "$temp_root/declared-homebrew.json" |
    sort -u >"$destination"; then
    printf 'Unable to read evaluated homebrew.%s for %s.\n' \
      "$option" "$darwin_configuration" >&2
    exit 2
  fi
}

# -----------------------------------------------------------------------------
# print_items
# @internal
# @description Prints every non-empty line of a file prefixed with a fixed-
# width label, one item per line.
# @arg $1 string Label printed before each item.
# @arg $2 path File to read items from.
# -----------------------------------------------------------------------------
print_items() {
  local prefix="$1"
  local file="$2"
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] && printf '%-20s %s\n' "$prefix" "$item"
  done <"$file"
}

# -----------------------------------------------------------------------------
# compare_inventory
# @internal
# @description Diffs a declared name list against the live installed list for
# one inventory kind (cask or tap), reporting anything missing or undeclared.
# @arg $1 string Inventory label (e.g. CASK, TAP), used in the report.
# @arg $2 path Sorted, unique file of declared names.
# @arg $3 path Sorted, unique file of live names.
# @set inventory_drift int Incremented by the number of items reported.
# -----------------------------------------------------------------------------
compare_inventory() {
  local label="$1"
  local declared="$2"
  local live="$3"
  local missing="$temp_root/$label-missing"
  local extra="$temp_root/$label-extra"

  comm -23 "$declared" "$live" >"$missing"
  comm -13 "$declared" "$live" >"$extra"

  if [[ -s "$missing" ]]; then
    print_items "MISSING $label" "$missing"
    inventory_drift=$((inventory_drift + $(wc -l <"$missing")))
  fi

  if [[ -s "$extra" ]]; then
    print_items "UNDECLARED $label" "$extra"
    inventory_drift=$((inventory_drift + $(wc -l <"$extra")))
  fi
}

# -----------------------------------------------------------------------------
# compare_formula_inventory
# @internal
# @description Diffs declared formulae against live formulae. Only explicitly
# requested formulae are reported as extra top-level inventory; reporting
# every undeclared formula would mislabel valid transitive dependencies as
# drift.
# @set inventory_drift int Incremented by the number of items reported.
# -----------------------------------------------------------------------------
compare_formula_inventory() {
  local missing="$temp_root/FORMULA-missing"
  local extra="$temp_root/FORMULA-extra"

  comm -23 "$temp_root/declared-formulae" "$temp_root/live-formulae" >"$missing"
  comm -13 "$temp_root/declared-formulae" "$temp_root/requested-formulae" \
    >"$extra"

  if [[ -s "$missing" ]]; then
    print_items 'MISSING FORMULA' "$missing"
    inventory_drift=$((inventory_drift + $(wc -l <"$missing")))
  fi

  if [[ -s "$extra" ]]; then
    print_items 'UNDECLARED FORMULA' "$extra"
    inventory_drift=$((inventory_drift + $(wc -l <"$extra")))
  fi
}

# -----------------------------------------------------------------------------
# path_provider
# @internal
# @description Classifies a resolved executable path as nix, homebrew, or
# other, based on well-known prefixes.
# @arg $1 path Executable path to classify.
# @stdout One of: nix, homebrew, other.
# -----------------------------------------------------------------------------
path_provider() {
  local candidate="$1"
  local resolved="$candidate"

  if [[ "$candidate" == "$brew_prefix/"* ]]; then
    printf 'homebrew\n'
  elif [[ "$candidate" == /nix/store/* ||
    "$candidate" == /etc/profiles/per-user/* ||
    "$candidate" == /run/current-system/sw/* ||
    "$candidate" == "$home_dir/.nix-profile/"* ]]; then
    printf 'nix\n'
  else
    if [[ -L "$candidate" ]]; then
      resolved="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    fi
    if [[ "$resolved" == "$brew_prefix/"* ]]; then
      printf 'homebrew\n'
    elif [[ "$resolved" == /nix/store/* ||
      "$resolved" == /etc/profiles/per-user/* ||
      "$resolved" == /run/current-system/sw/* ||
      "$resolved" == "$home_dir/.nix-profile/"* ]]; then
      printf 'nix\n'
    else
      printf 'other\n'
    fi
  fi
}

# -----------------------------------------------------------------------------
# brew_owner
# @internal
# @description Resolves a Homebrew-owned executable path back to its owning
# formula or cask full name, via the Cellar/Caskroom layout and the cached
# `brew info --json=v2` output.
# @arg $1 path Candidate executable path.
# @stdout The owning formula's full name, its short name if unresolved via
# jq, or "unknown" if the path isn't under Cellar/Caskroom.
# -----------------------------------------------------------------------------
brew_owner() {
  local candidate="$1"
  local resolved relative short_name full_name

  resolved="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
  case "$resolved" in
  "$brew_prefix/Cellar/"*)
    relative="${resolved#"$brew_prefix/Cellar/"}"
    short_name="${relative%%/*}"
    ;;
  "$brew_prefix/Caskroom/"*)
    relative="${resolved#"$brew_prefix/Caskroom/"}"
    short_name="${relative%%/*}"
    ;;
  *)
    printf 'unknown'
    return
    ;;
  esac

  full_name="$(jq -r --arg name "$short_name" '
    (
      [.formulae[]
        | select(.name == $name)
        | .full_name]
      +
      [.casks[]
        | select(.token == $name)
        | .full_token // .token]
    )[0] // empty
  ' "$temp_root/live-info.json")"
  printf '%s' "${full_name:-$short_name}"
}

# -----------------------------------------------------------------------------
# lookup_policy
# @internal
# @description Looks up the declared ownership policy for one (formula,
# command) pair.
# @arg $1 string Formula full name.
# @arg $2 string Command name.
# @stdout "<expected-winner>\t<rationale>" if a policy row matches; empty
# otherwise.
# -----------------------------------------------------------------------------
lookup_policy() {
  local formula="$1"
  local command_name="$2"

  awk -F '\t' -v formula="$formula" -v command_name="$command_name" '
    !/^[[:space:]]*#/ && $1 == formula && $2 == command_name {
      print $3 "\t" $4
      exit
    }
  ' "$policy_file"
}

# +++++++++++++++++++++++++++++ DATA COLLECTION ++++++++++++++++++++++++++++++ #

printf 'Evaluating declared Homebrew inventory for %s...\n' \
  "$darwin_configuration"
if ! nix eval --no-warn-dirty --json \
  --apply 'homebrew: { inherit (homebrew) brews casks taps; }' \
  "$flake_ref" >"$temp_root/declared-homebrew.json"; then
  printf 'Unable to evaluate the Homebrew inventory from %s.\n' \
    "$darwin_configuration" >&2
  exit 2
fi
declared_names brews "$temp_root/declared-formulae"
declared_names casks "$temp_root/declared-casks"
declared_names taps "$temp_root/declared-taps"

printf 'Reading live Homebrew inventory...\n'
if ! brew info --json=v2 --installed >"$temp_root/live-info.json"; then
  printf 'Unable to read installed Homebrew package metadata.\n' >&2
  exit 2
fi
if ! jq -e '
  (.formulae | type == "array") and (.casks | type == "array")
' "$temp_root/live-info.json" >/dev/null; then
  printf 'Homebrew returned malformed installed-package metadata.\n' >&2
  exit 2
fi
if ! brew list --formula --full-name |
  sort -u >"$temp_root/live-formulae"; then
  printf 'Unable to read the installed Homebrew formula inventory.\n' >&2
  exit 2
fi
if ! jq -r '.casks[] | .full_token // .token' \
  "$temp_root/live-info.json" | sort -u >"$temp_root/live-casks"; then
  printf 'Unable to read the installed Homebrew cask inventory.\n' >&2
  exit 2
fi
if ! brew tap | sort -u >"$temp_root/live-taps"; then
  printf 'Unable to read the installed Homebrew tap inventory.\n' >&2
  exit 2
fi

# installed_on_request distinguishes packages explicitly installed by the user
# from the much larger transitive dependency closure. Declared dependencies are
# still checked for presence above, but undeclared dependencies are not drift.
if ! jq -r '
  .formulae[]
  | select(any(.installed[]?; .installed_on_request == true))
  | .full_name
' "$temp_root/live-info.json" |
  sort -u >"$temp_root/requested-formulae"; then
  printf 'Unable to identify requested Homebrew formulae.\n' >&2
  exit 2
fi

printf '\nInventory\n'
printf '%-20s %s declared / %s installed (%s requested)\n' \
  'FORMULAE' \
  "$(wc -l <"$temp_root/declared-formulae" | tr -d ' ')" \
  "$(wc -l <"$temp_root/live-formulae" | tr -d ' ')" \
  "$(wc -l <"$temp_root/requested-formulae" | tr -d ' ')"
printf '%-20s %s declared / %s installed\n' \
  'CASKS' \
  "$(wc -l <"$temp_root/declared-casks" | tr -d ' ')" \
  "$(wc -l <"$temp_root/live-casks" | tr -d ' ')"
printf '%-20s %s declared / %s installed\n' \
  'TAPS' \
  "$(wc -l <"$temp_root/declared-taps" | tr -d ' ')" \
  "$(wc -l <"$temp_root/live-taps" | tr -d ' ')"

# +++++++++++++++++++++++++++++ INVENTORY DRIFT ++++++++++++++++++++++++++++++ #

printf '\nInventory drift\n'
compare_formula_inventory
compare_inventory CASK "$temp_root/declared-casks" "$temp_root/live-casks"
compare_inventory TAP "$temp_root/declared-taps" "$temp_root/live-taps"

if ((inventory_drift == 0)); then
  printf 'OK                   Declared and live top-level inventory match.\n'
fi

if [[ -s "$temp_root/FORMULA-extra" ]]; then
  printf '\nRemoval constraints for undeclared formulae\n'
  while IFS= read -r formula; do
    [[ -n "$formula" ]] || continue
    if ! dependants="$(brew uses --installed "$formula" 2>/dev/null |
      awk 'NR == 1 { result = $0; next } { result = result ", " $0 }
        END { print result }')"; then
      printf 'Unable to inspect installed users of %s.\n' "$formula" >&2
      exit 2
    fi
    if [[ -n "$dependants" ]]; then
      printf '%-20s %s <- %s\n' 'BLOCKED' "$formula" "$dependants"
    else
      printf '%-20s %s\n' 'NO DEPENDANTS' "$formula"
    fi
  done <"$temp_root/FORMULA-extra"
fi

# +++++++++++++++++++++++++ PATH OWNERSHIP ANALYSIS ++++++++++++++++++++++++++ #

printf '\nNix/Homebrew command ownership\n'

# Consider commands visible through PATH rather than every file in every keg.
# This catches opt-prefix entries such as Homebrew LLVM as well as the standard
# Homebrew bin directory. Build the candidate index once: rescanning every PATH
# directory separately for every command makes large development profiles
# needlessly slow.
path_index=0
: >"$temp_root/path-candidates-unsorted"
while IFS= read -r path_entry; do
  path_index=$((path_index + 1))
  if [[ -z "$path_entry" ]]; then
    printf '%-20s %s\n' 'UNSAFE PATH ENTRY' \
      'Empty component implicitly names the current directory.' >&2
    policy_issues=$((policy_issues + 1))
    continue
  fi
  if [[ "$path_entry" != /* || "$path_entry" == *[[:cntrl:]]* ]]; then
    printf '%-20s %q\n' 'UNSAFE PATH ENTRY' "$path_entry" >&2
    policy_issues=$((policy_issues + 1))
    continue
  fi
  [[ -d "$path_entry" ]] || continue
  for candidate in "$path_entry"/*; do
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue
    if [[ "$candidate" == *[[:cntrl:]]* ]]; then
      printf '%-20s %q\n' 'UNSAFE PATH ENTRY' "$candidate" >&2
      policy_issues=$((policy_issues + 1))
      continue
    fi
    printf '%s\t%d\t%s\t%s\n' \
      "${candidate##*/}" "$path_index" \
      "$(path_provider "$candidate")" "$candidate" \
      >>"$temp_root/path-candidates-unsorted"
  done
done < <(printf '%s' "$PATH" | tr ':' '\n')
sort -t $'\t' -k1,1 -k2,2n "$temp_root/path-candidates-unsorted" \
  >"$temp_root/path-candidates"

awk -F '\t' '
  function emit() {
    if (command_name != "" && nix_path != "" && brew_path != "") {
      print command_name "\t" winner_provider "\t" winner_path \
        "\t" nix_path "\t" brew_path
    }
  }
  $1 != command_name {
    emit()
    command_name = $1
    winner_provider = $3
    winner_path = $4
    nix_path = ""
    brew_path = ""
  }
  $3 == "nix" && nix_path == "" { nix_path = $4 }
  $3 == "homebrew" && brew_path == "" { brew_path = $4 }
  END { emit() }
' "$temp_root/path-candidates" >"$temp_root/path-overlaps"

: >"$temp_root/matched-policies"
while IFS=$'\t' read -r command_name winner_provider winner \
  nix_candidate brew_candidate; do
  overlaps=$((overlaps + 1))
  formula="$(brew_owner "$brew_candidate")"
  policy="$(lookup_policy "$formula" "$command_name")"
  expected="${policy%%$'\t'*}"
  rationale=''
  if [[ "$policy" == *$'\t'* ]]; then
    rationale="${policy#*$'\t'}"
  fi

  if [[ -n "$policy" ]]; then
    printf '%s\t%s\n' "$formula" "$command_name" \
      >>"$temp_root/matched-policies"
  fi

  if [[ -n "$expected" && "$winner_provider" != "$expected" ]]; then
    printf '%-20s %s expected %s, found %s (%s)\n' \
      'POLICY MISMATCH' "$command_name" "$expected" \
      "$winner_provider" "$rationale"
    if [[ "$winner_provider" == "homebrew" ]]; then
      path_conflicts=$((path_conflicts + 1))
    else
      policy_issues=$((policy_issues + 1))
    fi
    continue
  fi

  case "$winner_provider" in
  homebrew)
    if [[ "$expected" == "homebrew" ]]; then
      printf '%-20s %s (%s; policy: %s)\n' \
        'HOMEBREW-WINS' "$command_name" "$formula" "$rationale"
    else
      printf '%-20s %s -> %s (Nix: %s; owner: %s)\n' \
        'UNEXPECTED WINNER' "$command_name" "$winner" \
        "$nix_candidate" "$formula"
      [[ -n "$rationale" ]] &&
        printf '%-20s %s\n' 'POLICY' "$rationale"
      path_conflicts=$((path_conflicts + 1))
    fi
    ;;
  nix)
    printf '%s\n' "$formula" >>"$temp_root/nix-wins"
    if ((verbose)) || [[ "$expected" == "nix" ]]; then
      printf '%-20s %s -> %s (Homebrew: %s; owner: %s)\n' \
        'NIX-WINS' "$command_name" "$winner" "$brew_candidate" "$formula"
      [[ -n "$rationale" ]] &&
        printf '%-20s %s\n' 'POLICY' "$rationale"
    fi
    ;;
  *)
    other_winners=$((other_winners + 1))
    printf '%s\n' "$command_name" >>"$temp_root/other-wins"
    if ((verbose)); then
      printf '%-20s %s -> %s (Nix: %s; Homebrew: %s)\n' \
        'OTHER-WINS' "$command_name" "$winner" \
        "$nix_candidate" "$brew_candidate"
    fi
    ;;
  esac
done <"$temp_root/path-overlaps"

# ++++++++++++++++++++++++++++ POLICY CROSS-CHECK ++++++++++++++++++++++++++++ #

awk -F '\t' '!/^[[:space:]]*#/ && NF { print $1 "\t" $2 }' "$policy_file" |
  sort -u >"$temp_root/declared-policies"
sort -u "$temp_root/matched-policies" >"$temp_root/matched-policies-sorted"
comm -23 "$temp_root/declared-policies" "$temp_root/matched-policies-sorted" \
  >"$temp_root/stale-policies"
if [[ -s "$temp_root/stale-policies" ]]; then
  print_items 'STALE POLICY' "$temp_root/stale-policies"
  policy_issues=$((policy_issues + $(wc -l <"$temp_root/stale-policies")))
fi

if ((overlaps)) && ((verbose == 0)) && [[ -s "$temp_root/nix-wins" ]]; then
  printf '%-20s ' 'BENIGN OVERLAPS'
  first_owner=1
  while IFS=$' \t' read -r owner_count owner_name; do
    [[ -n "$owner_count" && -n "$owner_name" ]] || continue
    ((first_owner)) || printf ', '
    printf '%s (%d)' "$owner_name" "$owner_count"
    first_owner=0
  done < <(sort "$temp_root/nix-wins" | uniq -c)
  printf '\n'
  printf '%-20s %s\n' 'DETAIL' 'Run with --verbose to list every benign overlap.'
fi

if ((other_winners)) && ((verbose == 0)); then
  printf '%-20s ' 'OTHER WINNERS'
  first_command=1
  while IFS= read -r command_name; do
    [[ -n "$command_name" ]] || continue
    ((first_command)) || printf ', '
    printf '%s' "$command_name"
    first_command=0
  done < <(sort -u "$temp_root/other-wins")
  printf '\n'
fi

if ((overlaps == 0)); then
  printf 'OK                   No commands are visible from both package managers.\n'
fi

# +++++++++++++++++++++++++++++++++ SUMMARY ++++++++++++++++++++++++++++++++++ #

issues=$((inventory_drift + path_conflicts + other_winners + policy_issues))
printf '\nSummary\n'
printf 'Top-level inventory drift: %d item(s).\n' "$inventory_drift"
printf 'Visible Nix/Homebrew command overlaps: %d.\n' "$overlaps"
printf 'Unexpected Homebrew PATH winners: %d.\n' "$path_conflicts"
printf 'Other PATH winners: %d.\n' "$other_winners"
printf 'Ownership policy issues: %d.\n' "$policy_issues"

if ((issues)); then
  printf 'Package ownership audit found %d actionable issue(s); no changes were made.\n' \
    "$issues" >&2
  exit 1
fi

printf 'Package ownership audit passed; no changes were made.\n'

# ============================================================================ #
# End of audit-package-ownership.sh.
