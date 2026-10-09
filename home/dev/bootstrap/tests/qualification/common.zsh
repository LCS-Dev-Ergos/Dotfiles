#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++ NATIVE QUALIFICATION SHARED HELPERS ++++++++++++++++++++ #
# ============================================================================ #
# Sourced by the qualification scripts after they set `executable` and `log`;
# sourcing creates the disposable root, which holds the home, temporary,
# cache, state, data and configuration directories and is removed on exit
# unless DEV_BOOTSTRAP_KEEP_ROOT=1. The executor starts from an empty
# environment, so no exported manager root can redirect writes into the real
# home. The native package manager stays global: packages it installs are
# reported, not undone.
# ============================================================================ #

zmodload zsh/datetime

typeset analysis="${DEV_BOOTSTRAP_ANALYSIS_PYTHON:-$(whence -p python3)}"
[[ -x "$analysis" ]] || { print -u2 'The report needs python3'; return 2; }

# Selections and settings the real managers keep under the real home.
typeset -ga guarded=(
  .local/share/fnm/aliases/default .pyenv/version .opam/config
  .rustup/settings.toml .ghcup/bin/ghc .ghcup/bin/cabal
  .ghcup/bin/haskell-language-server-wrapper .elan/settings.toml
  .rbenv/version .sdkman/candidates/java/current
  .sdkman/candidates/kotlin/current .sdkman/candidates/maven/current
  .sdkman/candidates/gradle/current .juliaup/juliaup.json
  .local/share/coursier/bin/scala
  'Library/Application Support/Coursier/bin/scala' .dotnet/dotnet
  .miniforge3/bin/conda
)
# Directories whose every entry is a manager's selection or launcher.
typeset -ga guarded_directories=(
  .local/share/coursier/bin 'Library/Application Support/Coursier/bin'
)

_snapshot_home() {
  local entry file
  command ls -A "$HOME"
  for entry in "${guarded[@]}"; do
    if [[ -L "$HOME/$entry" ]]; then
      print -r -- "$entry link $(command readlink "$HOME/$entry")"
    elif [[ -f "$HOME/$entry" ]]; then
      print -r -- "$entry file $(command cksum < "$HOME/$entry")"
    else
      print -r -- "$entry absent"
    fi
  done
  for entry in "${guarded_directories[@]}"; do
    for file in "$HOME/$entry"/*(DN.); do
      print -r -- "$entry/${file:t} file $(command cksum < "$file")"
    done
  done
}

_snapshot_packages() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew list --formula -1
  elif [[ -x /usr/bin/pacman ]]; then
    /usr/bin/pacman -Qq
  fi
}

# -----------------------------------------------------------------------------
# _isolated
# @description Runs a command with the disposable root as its whole
#   environment, keeping only the account name and proxy settings.
# @arg $@ string Extra NAME=value assignments, then the command.
# -----------------------------------------------------------------------------
_isolated() {
  local -a proxies=()
  local name
  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    [[ -n "${(P)name:-}" ]] && proxies+=("$name=${(P)name}")
  done
  command env -i HOME="$root/home" USER="$USER" LOGNAME="$USER" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 TERM=dumb \
    TMPDIR="$root/tmp" XDG_CACHE_HOME="$root/cache" \
    XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
    XDG_CONFIG_HOME="$root/config" "${proxies[@]}" "$@"
}

_executor() {
  _isolated "$executable" "$@"
}

# -----------------------------------------------------------------------------
# _requirements
# @description Reads each ecosystem's requirements from the executor's catalog,
#   which rejects a selection without them.
# @set requires assoc Language to its space-separated requirements.
# -----------------------------------------------------------------------------
_requirements() {
  typeset -gA requires
  local language required
  _executor plan --json > "$log/catalog.json" 2> "$log/catalog.err" || {
    print -u2 'The executor did not report its catalog'
    return 1
  }
  while IFS=$'\t' read -r language required; do
    requires[$language]="$required"
  done < <("$analysis" -I -c '
import json, sys
for entry in json.load(open(sys.argv[1]))["catalog"]:
    print(entry["language"], " ".join(entry["requires"]), sep="\t")
' "$log/catalog.json")
}

# -----------------------------------------------------------------------------
# _selection
# @description Builds --only arguments for ecosystems and their requirements.
# @arg $@ string Ecosystems.
# @set reply array The arguments, each requirement once.
# -----------------------------------------------------------------------------
_selection() {
  local language required
  local -aU languages=()
  reply=()
  for language in "$@"; do
    (( ${+requires[$language]} )) || {
      print -u2 "Unknown ecosystem: $language"
      return 2
    }
    languages+=(${=requires[$language]} "$language")
  done
  for language in "${languages[@]}"; do
    reply+=(--only "$language")
  done
}

# The root is created here, at the sourcing script's top level: an EXIT trap
# set inside a function would run when that function returns.
typeset root
root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-native-adapters.XXXXXX")" || return 1
root="${root:A}"
[[ -d "$root" && "$root:t" == bootstrap-native-adapters.* ]] || return 1
command mkdir -p "$log" "$root"/{home,tmp,cache,state,data,config}
log="${log:A}"
if [[ "${DEV_BOOTSTRAP_KEEP_ROOT:-0}" != 1 ]]; then
  trap 'command rm -rf -- "$root"' EXIT
fi
trap 'exit 130' INT TERM HUP
print -r -- "root=$root"

# ============================================================================ #
# End of tests/qualification/common.zsh
