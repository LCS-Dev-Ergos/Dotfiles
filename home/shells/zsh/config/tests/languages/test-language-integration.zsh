#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ LANGUAGE INTEGRATION TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies deferred FNM/opam ordering, reload hook uniqueness, local switch
# selection and preservation of explicit Node defaults. Opam root changes and
# failed probes must permit recovery without evaluating partial output.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir languages)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

# Isolated environment fixtures for language manager integrations.
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export FNM_DIR="$fixture_root/fnm"
export ZSH_CONFIG_DIR="$test_root"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
export PATH="$fixture_root/bin:/usr/bin:/bin"
export LANGUAGE_TEST_DEFAULT_MARKER="$fixture_root/default-mutated"

unset OPAMROOT OPAMSWITCH OPAM_SWITCH_PREFIX FNM_MULTISHELL_PATH _FNM_LAZY_INIT \
  PYENV_ROOT RBENV_ROOT GHCUP_INSTALL_BASE_PREFIX CARGO_HOME RUSTUP_HOME \
  SDKMAN_DIR JAVA_HOME HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY
# Load platform detection once before selecting the fixture platform. The
# dispatcher reuses these helpers; it must not rediscover the host afterward.
source "$test_root/runtime-helpers.zsh"
export PLATFORM=test

command mkdir -p \
  "$HOME/.opam/opam-init" \
  "$fixture_root/bin" \
  "$fixture_root/global" \
  "$fixture_root/project/_opam" \
  "$FNM_DIR" \
  "$fixture_root/ms/bin"

# Mock fnm: lists version, records default mutations, and emits multishell env exports.
print -rl -- '#!/bin/sh' \
  'case "$1" in' \
  'list) echo "v26.10.0" ;;' \
  'default) touch "$LANGUAGE_TEST_DEFAULT_MARKER" ;;' \
  'env) printf '\''export FNM_MULTISHELL_PATH="%s/ms"\n'\'' "${HOME%/home}" ;;' \
  'esac' > "$fixture_root/bin/fnm"
command chmod 700 "$fixture_root/bin/fnm"

# Stand-in for opam-init shell integration script.
print -rl -- '_opam_env_hook() { :; }' \
  'precmd_functions=(${precmd_functions:#_opam_env_hook} _opam_env_hook)' \
  > "$HOME/.opam/opam-init/init.zsh"

# Mock opam: exports environment marker when invoked as `opam env`.
print -rl -- '#!/bin/sh' 'if [ "$1" = env ]; then echo "export LANGUAGE_TEST_OPAM_APPLIED=1"; fi' \
  > "$fixture_root/bin/opam"
command chmod 700 "$fixture_root/bin/opam"

autoload -Uz add-zsh-hook
typeset -ga precmd_functions deferred

# Intercept deferred helper registrations during language initialization.
_zsh_defer() { deferred+=("$1"); }

# Sourcing in a global directory must defer FNM initialization before opam env.
cd "$fixture_root/global"
source "$test_root/lib/80-languages.zsh"
typeset fixture_manager
for fixture_manager in fnm opam; do
  [[ "$(whence -p "$fixture_manager")" == "$fixture_root/bin/$fixture_manager" ]] || {
    print -u2 "FAIL: $fixture_manager escaped its fixture"
    return 1
  }
done
[[ "${deferred[*]}" == '_fnm_lazy_init _zsh_opam_env_apply' ]] || {
  print -u2 "FAIL: deferred order: ${deferred[*]}"
  return 1
}

# Re-sourcing 80-languages.zsh must not duplicate the opam precmd hook.
source "$test_root/lib/80-languages.zsh"
typeset -a opam_hooks=("${(@M)precmd_functions:#_zsh_opam_env_hook}")
(( ${#opam_hooks} == 1 )) || {
  print -u2 'FAIL: repeated sourcing duplicates opam hooks'
  return 1
}

# In a local project switch directory, global opam env apply must be omitted.
deferred=()
cd "$fixture_root/project"
source "$test_root/lib/80-languages.zsh"
[[ "${deferred[*]}" == '_fnm_lazy_init' ]] || {
  print -u2 'FAIL: a local switch was replaced by global deferred opam setup'
  return 1
}

# Local opam environment must be applied when executing the precmd hook.
_zsh_opam_env_hook
[[ "$LANGUAGE_TEST_OPAM_APPLIED" == 1 ]] || {
  print -u2 'FAIL: local opam env was not applied'
  return 1
}

# Lazy FNM initialization must not mutate explicit user Node defaults.
_fnm_lazy_init
[[ ! -e "$LANGUAGE_TEST_DEFAULT_MARKER" ]] || {
  print -u2 'FAIL: shell initialization changes the global Node default'
  return 1
}

# Cache identity follows OPAMROOT even when both roots lack a config file.
export LANGUAGE_TEST_OPAM_CALLS="$fixture_root/opam-calls"
print -rl -- '#!/bin/sh' \
  'echo call >> "$LANGUAGE_TEST_OPAM_CALLS"' \
  'if [ "${LANGUAGE_TEST_OPAM_FAIL:-}" = 1 ]; then' \
  '  echo "export LANGUAGE_TEST_OPAM_PARTIAL=1"; exit 1' \
  'fi' \
  'echo "export LANGUAGE_TEST_OPAM_ROOT=\"$OPAMROOT\""' \
  > "$fixture_root/bin/opam"

command mkdir -p "$fixture_root/opam-one" "$fixture_root/opam-two"

export OPAMROOT="$fixture_root/opam-one"
_zsh_opam_env_hook

export OPAMROOT="$fixture_root/opam-two"
_zsh_opam_env_hook
[[ "$LANGUAGE_TEST_OPAM_ROOT" == "$OPAMROOT" ]] || {
  print -u2 'FAIL: opam cache ignores root changes'
  return 1
}

# Failed output must not be evaluated or suppress the next prompt retry.
export OPAMROOT="$fixture_root/opam-one"
export LANGUAGE_TEST_OPAM_FAIL=1
if _zsh_opam_env_hook; then
  print -u2 'FAIL: failed opam env reports success'
  return 1
fi
[[ -z "${LANGUAGE_TEST_OPAM_PARTIAL:-}" ]] || {
  print -u2 'FAIL: partial output from failed opam env was evaluated'
  return 1
}

# A retry following a failure must re-evaluate opam and update the cache.
unset LANGUAGE_TEST_OPAM_FAIL
_zsh_opam_env_hook
[[ "$LANGUAGE_TEST_OPAM_ROOT" == "$OPAMROOT" &&
   "$(wc -l < "$LANGUAGE_TEST_OPAM_CALLS")" -eq 4 ]] || {
  print -u2 'FAIL: failed opam environment was cached instead of retried'
  return 1
}

# Deferred initialization must also invalidate a previously successful stamp.
export LANGUAGE_TEST_OPAM_FAIL=1
if _zsh_opam_env_apply; then
  print -u2 'FAIL: deferred opam failure reports success'
  return 1
fi
[[ -z "$_ZSH_OPAM_ENV_STAMP" ]] || {
  print -u2 'FAIL: deferred opam failure leaves a successful cache stamp'
  return 1
}

# Prompt hook must retry opam evaluation following a deferred failure.
unset LANGUAGE_TEST_OPAM_FAIL
_zsh_opam_env_hook
[[ "$(wc -l < "$LANGUAGE_TEST_OPAM_CALLS")" -eq 6 ]] || {
  print -u2 'FAIL: deferred opam failure was not retried by the prompt hook'
  return 1
}

# Native FNM must be discoverable on PATH before language initialization runs.
command cp "$fixture_root/bin/fnm" "$FNM_DIR/fnm"
PATH=/usr/bin:/bin
export LCS_RUNTIME_MANAGER_BACKEND=native
export LCS_NATIVE_FNM_READY=1

source "$test_root/lib/80-languages.zsh"
[[ "$(whence -p fnm)" == "$FNM_DIR/fnm" ]] || {
  print -u2 'FAIL: native FNM is unavailable before language initialization'
  return 1
}

# Shell initialization must preserve an explicit external PYENV_ROOT.
command mkdir -p "$HOME/.pyenv" "$fixture_root/custom-python/bin"
export PYENV_ROOT="$fixture_root/custom-python"

source "$test_root/languages/python.zsh"
[[ "$PYENV_ROOT" == "$fixture_root/custom-python" ]] || {
  print -u2 'FAIL: shell integration replaced the recovery Python root'
  return 1
}

print -r -- 'PASS: language ordering, local switches, explicit roots and Node defaults'

# ============================================================================ #
# End of tests/languages/test-language-integration.zsh
