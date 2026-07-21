#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ CUSTOM COMPLETIONS TEST ++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies lib/85-completions.zsh: completion generation is deferred, shdoc
# metadata (@arg path/boolean/string, @option, @noargs) produces the correct
# _arguments spec, hyphenated names and @internal functions are handled
# correctly, a pre-existing specialized completion is preserved rather than
# overwritten, the generated cache is created with mode 600 and rebuilt when
# insecure, and NOMATCH state is not corrupted by the completion function.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir completions)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

mkdir -p \
  "$fixture_root/config/functions" \
  "$fixture_root/config/scripts" \
  "$fixture_root/config/completions" \
  "$fixture_root/cache"
cp "$test_root/scripts/zfuncs-index.awk" "$fixture_root/config/scripts/"
cp "$test_root/scripts/generate-zsh-completions.zsh" \
  "$fixture_root/config/scripts/"

cat > "$fixture_root/config/functions/example.zsh" <<'EOF'
# -----------------------------------------------------------------------------
# alpha
# @description Processes a file with typed arguments and options.
# @arg $1 path Input file.
# @arg $2 boolean Optional confirmation value.
# @option -n | --dry-run Preview the operation.
# @option --quiet Suppress informational output.
# -----------------------------------------------------------------------------
alpha() {
  return 0
}

# -----------------------------------------------------------------------------
# hyphen-command
# @description Verifies generated completion for a hyphenated function name.
# @noargs
# -----------------------------------------------------------------------------
hyphen-command() {
  return 0
}

# -----------------------------------------------------------------------------
# noarg
# @description Performs a deterministic operation without arguments.
# @noargs
# -----------------------------------------------------------------------------
noarg() {
  return 0
}

# -----------------------------------------------------------------------------
# freeform
# @description Accepts arbitrary string values without a completion action.
# @arg $@ string Free-form values.
# -----------------------------------------------------------------------------
freeform() {
  return 0
}

# -----------------------------------------------------------------------------
# preserved
# @description Exercises preservation of a specialized completion.
# @arg $1 string Input value.
# -----------------------------------------------------------------------------
preserved() {
  return 0
}

# -----------------------------------------------------------------------------
# private_helper
# @internal
# @description Must not be registered as a public completion.
# @noargs
# -----------------------------------------------------------------------------
private_helper() {
  return 0
}
EOF

export ZSH_CONFIG_DIR="$fixture_root/config"
export ZSH_CUSTOM_COMPLETION_CONFIG_DIR="$fixture_root/config"
export XDG_CACHE_HOME="$fixture_root/cache"
export ZDOTDIR="$fixture_root/config"
export ZSH_COMPDUMP="$fixture_root/zcompdump"
export ZSH_DEFER_COMPLETIONS=1
export ZSH_DISABLE_COMPFIX=true
export HYDE_ENABLED=0

typeset deferred_completion_fn=""
_zsh_defer() {
  deferred_completion_fn="$1"
}

source "$test_root/lib/85-completions.zsh"
[[ "$deferred_completion_fn" == _late_completions ]] || {
  print -u2 "FAIL: custom completion generation was not deferred"
  return 1
}

_fixture_specific_completion() {
  return 0
}
compdef _fixture_specific_completion preserved

_zsh_load_custom_completions || {
  print -u2 "FAIL: shdoc completion cache could not be loaded"
  return 1
}

[[ "${_comps[alpha]-}" == _zsh_custom_completion ]] || {
  print -u2 "FAIL: generated completion was not registered"
  return 1
}
[[ "${_comps[hyphen-command]-}" == _zsh_custom_completion ]] || {
  print -u2 "FAIL: hyphenated command completion was not registered"
  return 1
}
[[ "${_comps[noarg]-}" == _zsh_custom_completion ]] || {
  print -u2 "FAIL: @noargs completion was not registered"
  return 1
}
[[ "${_comps[freeform]-}" == _zsh_custom_completion ]] || {
  print -u2 "FAIL: actionless string completion was not registered"
  return 1
}
[[ "${_comps[preserved]-}" == _fixture_specific_completion ]] || {
  print -u2 "FAIL: specialized completion was overwritten"
  return 1
}
[[ -z "${_comps[private_helper]-}" ]] || {
  print -u2 "FAIL: @internal function received a completion"
  return 1
}

typeset cache_file="$fixture_root/cache/zsh/completions/_custom-functions-v1"
[[ -f "$cache_file" ]] || {
  print -u2 "FAIL: generated completion cache was not created"
  return 1
}
[[ "$(command stat -f '%Lp' "$cache_file" 2>/dev/null ||
       command stat -c '%a' "$cache_file")" == 600 ]] || {
  print -u2 "FAIL: generated completion cache does not have mode 600"
  return 1
}

typeset -ga captured_arguments=()
typeset -gi captured_nomatch=-1
_arguments() {
  captured_arguments=("$@")
  [[ -o nomatch ]] && captured_nomatch=1 || captured_nomatch=0
}

typeset saved_path="$PATH"
PATH=""
service=alpha
words=(alpha "")
_zsh_custom_completion
PATH="$saved_path"

[[ "${captured_arguments[*]}" == *'1:Input file.:_files'* ]] || {
  print -u2 "FAIL: path metadata did not produce _files completion"
  return 1
}
typeset expected_boolean_spec='2:Optional confirmation value.:(true false)'
[[ "${captured_arguments[*]}" == *"$expected_boolean_spec"* ]] || {
  print -u2 "FAIL: boolean metadata did not produce value completion"
  return 1
}
[[ "${captured_arguments[*]}" == *'(-n --dry-run)-n['* ]] || {
  print -u2 "FAIL: short option alias was not generated"
  return 1
}
[[ "${captured_arguments[*]}" == *'(-n --dry-run)--dry-run['* ]] || {
  print -u2 "FAIL: long option alias was not generated"
  return 1
}

captured_arguments=()
service=noarg
_zsh_custom_completion
[[ "${captured_arguments[-1]}" == '1:no additional arguments' ]] || {
  print -u2 "FAIL: @noargs did not suppress default argument completion"
  return 1
}

captured_arguments=()
captured_nomatch=-1
() {
  setopt localoptions nonomatch
  service=freeform
  _zsh_custom_completion
}
[[ "${captured_arguments[-1]}" == '*:Free-form values.' ]] || {
  print -u2 "FAIL: empty completion action produced a trailing colon"
  return 1
}
(( captured_nomatch == 0 )) || {
  print -u2 "FAIL: custom completion reset compinit's NONOMATCH option"
  return 1
}

chmod 666 "$cache_file"
_zsh_load_custom_completions
[[ "$(command stat -f '%Lp' "$cache_file" 2>/dev/null ||
       command stat -c '%a' "$cache_file")" == 600 ]] || {
  print -u2 "FAIL: insecure completion cache was not rebuilt safely"
  return 1
}

print -r -- \
  "PASS: generated completions, secure cache, and native preservation"

# ============================================================================ #
# End of tests/test-custom-completions.zsh
