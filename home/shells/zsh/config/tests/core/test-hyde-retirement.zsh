#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ HYDE RETIREMENT TEST +++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that retired HyDE home files and inherited ownership flags cannot
# select plugins, prompts or compositor configuration in either startup phase.
# Isolated fixtures retain shared Linux defaults and explicit compositor paths.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir hyde-retirement)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

command mkdir -p "$fixture_root/config/lib" "$fixture_root/config/functions" \
  "$fixture_root/config/conf.d/hyde"
typeset file
for file in .hyde.zshrc .user.zsh config/user.zsh config/conf.d/hyde/shell.zsh; do
  print -r -- 'RETIRED_SOURCE_LOADED=1' > "$fixture_root/$file"
done
print -r -- 'CUSTOM_PLUGINS_LOADED=1' > "$fixture_root/config/lib/20-zinit.zsh"
print -r -- '_zsh_init_prompt_system() { CUSTOM_PROMPT_LOADED=1; }' \
  > "$fixture_root/config/lib/30-prompt.zsh"
print -r -- ':' > "$fixture_root/config/functions/fixture.zsh"

command env -i HOME="$fixture_root" PATH="$PATH" \
  ZDOTDIR="$fixture_root/config" DOTFILES_ZSH_ROOT="$test_root:h" \
  HYDE_ENABLED=1 HYDE_ZSH_NO_PLUGINS=0 HYDE_ZSH_PROMPT=1 zsh -dfc '
    source "$DOTFILES_ZSH_ROOT/zshrc" || exit 1
    [[ -z "${RETIRED_SOURCE_LOADED:-}" && "$CUSTOM_PLUGINS_LOADED" == 1 &&
       "$CUSTOM_PROMPT_LOADED" == 1 ]]
  ' || {
  print -u2 'FAIL: interactive startup imported retired HyDE files'
  return 1
}

command env -i HOME="$fixture_root" PATH="$PATH" NIX_PROFILES=fixture \
  ZSH_CONFIG_DIR="$test_root" HYDE_ENABLED=1 HYDE_ZSH_NO_PLUGINS=0 \
  HYDE_ZSH_PROMPT=1 HYPRLAND_CONFIG="$fixture_root/.local/share/hypr/hyprland.conf" \
  zsh -dfc '
    OSTYPE=linux-gnu
    source "$ZSH_CONFIG_DIR/.zshenv" || exit 1
    source "$ZSH_CONFIG_DIR/.zshenv" || exit 1
    [[ -z "${HYDE_ENABLED:-}" && -z "${HYDE_ZSH_PROMPT:-}" &&
       -z "${HYPRLAND_CONFIG:-}" && "$XDG_STATE_HOME" == "$HOME/.local/state" &&
       "$LESSHISTFILE" == "$XDG_STATE_HOME/lesshst" ]] || exit 1
    typeset -a local_entries=("${(@M)path:#$HOME/.local/bin}")
    (( ${#local_entries} == 1 ))
  ' || {
  print -u2 'FAIL: Linux environment retained HyDE state or duplicated PATH'
  return 1
}

command env -i HOME="$fixture_root" PATH="$PATH" NIX_PROFILES=fixture \
  ZSH_CONFIG_DIR="$test_root" HYPRLAND_CONFIG=custom.lua zsh -dfc '
    OSTYPE=linux-gnu
    source "$ZSH_CONFIG_DIR/.zshenv" || exit 1
    [[ "$HYPRLAND_CONFIG" == custom.lua ]]
  ' || {
  print -u2 'FAIL: an explicit custom compositor path was lost'
  return 1
}

command env -i HOME="$fixture_root" PATH="$PATH" NIX_PROFILES=fixture \
  ZSH_CONFIG_DIR="$test_root" zsh -dfc '
    OSTYPE=darwin
    source "$ZSH_CONFIG_DIR/.zshenv" || exit 1
    [[ -z "${LESSHISTFILE:-}" && "$ZDOTDIR" == "$HOME" ]]
  ' || {
  print -u2 'FAIL: Linux environment settings leaked into macOS'
  return 1
}

# Direct module sourcing must also ignore inherited desktop ownership flags.
command env -i HOME="$fixture_root" PATH="$PATH" ZSH_CONFIG_DIR="$test_root" \
  HYDE_ENABLED=1 HYDE_ZSH_NO_PLUGINS=0 HYDE_ZSH_PROMPT=1 zsh -dfc '
    source "$ZSH_CONFIG_DIR/lib/30-prompt.zsh" || exit 1
    source "$ZSH_CONFIG_DIR/functions/omz-compatibility.zsh" || exit 1
    (( $+functions[_zsh_init_prompt_system] && $+functions[detect-clipboard] ))
  ' || {
  print -u2 'FAIL: inherited HyDE flags disabled shared shell modules'
  return 1
}
print -r -- 'PASS: retired HyDE files/flags cannot override shared shell startup'

# ============================================================================ #
# End of tests/core/test-hyde-retirement.zsh
