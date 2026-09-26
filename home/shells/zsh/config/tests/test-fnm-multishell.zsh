#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ FNM MULTISHELL LIFECYCLE TEST +++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that a shell claims the link `fnm env` creates under its own PID,
# replaces an earlier claim and an exec'ed predecessor's link, reaps the links
# of dead shells and old fnm-named links, keeps live and recent ones, removes
# its own link on exit but not when a subshell exits, puts that link ahead of
# fnm's default alias in PATH, and that fnm_clean applies the same rule.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir fnm)" || return 1
typeset -a live_pids=()
trap '
  (( ${#live_pids} )) && kill "${live_pids[@]}" 2>/dev/null
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset fake_bin="$fixture_root/bin"
typeset ms_dir="$fixture_root/state/fnm_multishells"
command mkdir -p "$fake_bin" "$fixture_root/home" \
  "$fixture_root/fnm/aliases/default/bin" "$ms_dir"

# A stand-in for fnm: `env` creates a link named after its own PID, exactly
# as fnm does, and prints the matching exports; every other command no-ops.
{
  print -r -- '#!/bin/sh'
  print -r -- 'case "$1" in'
  print -r -- '  env)'
  print -r -- '    link="$XDG_STATE_HOME/fnm_multishells/$$_$(date +%s)000"'
  print -r -- '    ln -s "$FNM_DIR/aliases/default" "$link" || exit 1'
  print -r -- '    printf '\''export FNM_MULTISHELL_PATH="%s"\n'\'' "$link"'
  print -r -- '    printf '\''export PATH="%s/bin":"$PATH"\n'\'' "$link" ;;'
  print -r -- 'esac'
} >| "$fake_bin/fnm"
command chmod 700 "$fake_bin/fnm"

export HOME="$fixture_root/home"
export XDG_STATE_HOME="$fixture_root/state"
export FNM_DIR="$fixture_root/fnm"
export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
export ZSH_FAST_START=1
export PLATFORM=test
export PATH="$fake_bin:/usr/bin:/bin"
unset FNM_MULTISHELL_PATH XDG_RUNTIME_DIR HOMEBREW_PREFIX

# Preamble for each child shell: the real module, as a shell loads it.
# The loader has defined the hook arrays by then; the Opam section reads one.
typeset preamble='
  autoload -Uz add-zsh-hook
  typeset -ga precmd_functions
  source "$ZSH_CONFIG_DIR/runtime-helpers.zsh"
  source "$ZSH_CONFIG_DIR/lib/80-languages.zsh"
'

_fail() {
  print -u2 "FAIL: $*"
  return 1
}

# ----- Fixtures --------------------------------------------------------------
# A PID that is certainly gone, and one that stays alive for the test.
command sh -c 'exit 0' &
typeset dead_pid=$!
wait "$dead_pid" || true
command sleep 300 &
typeset live_pid=$!
live_pids+=("$live_pid")

_seed() {
  ln -s "$FNM_DIR/aliases/default" "$ms_dir/$1"
  [[ -z "${2:-}" ]] || command touch -h -t "$2" "$ms_dir/$1"
}
# Eight days old: past the seven-day limit for fnm-named links.
zmodload zsh/datetime
typeset old_stamp
strftime -s old_stamp %Y%m%d%H%M $(( EPOCHSECONDS - 8 * 86400 ))

_seed "zsh-${dead_pid}_1"
_seed "zsh-${live_pid}_1"
_seed "111_1" "$old_stamp"
_seed "222_2_0000000001" "$old_stamp"
_seed "333_3"

# ----- Claim, reap, re-init --------------------------------------------------
typeset claim_out
claim_out="$(zsh -f -c "$preamble"'
  zmodload zsh/system
  # A link left by the shell this one replaced with exec: same PID.
  ln -s "$FNM_DIR/aliases/default" "$XDG_STATE_HOME/fnm_multishells/zsh-${sysparams[pid]}_5"
  _fnm_lazy_init || exit 1
  first="$FNM_MULTISHELL_PATH"
  print -r -- "pid=${sysparams[pid]}"
  print -r -- "first=$first"
  print -r -- "inpath=${path[(Ie)$first/bin]}"
  print -r -- "stale=${#${(M)path:#*/fnm_multishells/<->_*}}"
  # PATH lost the link: a second initialization replaces the first claim.
  path=("${(@)path:#$first/bin}")
  _fnm_lazy_init || exit 1
  print -r -- "second=$FNM_MULTISHELL_PATH"
  ( exit 0 )
  print -r -- "after_subshell=$([[ -L $FNM_MULTISHELL_PATH ]] && print kept)"
  ls "$XDG_STATE_HOME/fnm_multishells" | sort | sed "s/^/entry=/"
')" || _fail "claim child failed"

typeset -A got=()
typeset -a entries=()
typeset line
for line in "${(@f)claim_out}"; do
  case "$line" in
    entry=*) entries+=("${line#entry=}") ;;
    *=*) got[${line%%=*}]="${line#*=}" ;;
  esac
done
typeset child_pid="${got[pid]:-}" first="${got[first]:-}" second="${got[second]:-}"

[[ -n "$child_pid" && "$first" == "$ms_dir/zsh-${child_pid}_"<-> ]] ||
  _fail "first claim is not named after the shell PID: $first"
[[ "${got[inpath]:-0}" != 0 ]] || _fail "PATH does not contain the claimed link"
[[ "${got[stale]:-}" == 0 ]] || _fail "PATH still holds the fnm-named link"
[[ "$second" == "$ms_dir/zsh-${child_pid}_"<-> && "$second" != "$first" ]] ||
  _fail "re-initialization did not claim a new link: $second"
[[ "${got[after_subshell]:-}" == kept ]] ||
  _fail "a subshell exit removed the shell's link"

# After the child exited: its link is gone, and only live or recent foreign
# links survive the reap.
typeset -a expected=("333_3" "zsh-${live_pid}_1")
typeset -a remaining=("$ms_dir"/*(N@:t))
[[ "${(j: :)${(o)remaining}}" == "${(j: :)${(o)expected}}" ]] ||
  _fail "unexpected links after exit: ${remaining[*]}"
# While the child ran, the reap had already left exactly its own second link.
typeset -a own=(${(M)entries:#zsh-${child_pid}_*})
[[ ${#own} == 1 && "$ms_dir/${own[1]}" == "$second" ]] ||
  _fail "earlier claims were not replaced: ${own[*]}"
typeset -a foreign=(${(M)entries:#<->_*})
[[ "${foreign[*]}" == "333_3" ]] ||
  _fail "stale fnm-named links survived the reap: ${entries[*]}"

# ----- Exit signals ----------------------------------------------------------
typeset hup_out
hup_out="$(zsh -f -c "$preamble"'
  _fnm_lazy_init || exit 1
  print -r -- "$FNM_MULTISHELL_PATH"
  kill -HUP $sysparams[pid]
  sleep 5
' 2>/dev/null)" || true
[[ -n "$hup_out" && ! -L "$hup_out" ]] || _fail "SIGHUP left the link: $hup_out"

# ----- PATH order ------------------------------------------------------------
# This shell's link must precede fnm's default alias whether PATH is rebuilt
# from the template (cache miss) or restored from the cache (hit).
typeset order_out
order_out="$(XDG_CACHE_HOME="$fixture_root/cache" PLATFORM=macOS \
  zsh -f -c "$preamble"'
  source "$ZSH_CONFIG_DIR/lib/90-path.zsh"
  _fnm_lazy_init || exit 1
  _order() {
    local own=${path[(Ie)$FNM_MULTISHELL_PATH/bin]}
    local alias=${path[(Ie)$FNM_DIR/aliases/default/bin]}
    (( own && alias && own < alias )) && print -r -- "$1=ok" || print -r -- "$1=bad"
  }
  _order miss
  saved="$PATH"
  zsh_rebuild_path
  PATH="$saved"
  zsh_rebuild_path
  _order hit
')" || _fail "PATH order child failed"
[[ "$order_out" == $'miss=ok\nhit=ok' ]] ||
  _fail "the shell's fnm link does not precede the default alias: $order_out"

# ----- fnm_clean -------------------------------------------------------------
source "$test_root/runtime-helpers.zsh"
autoload -Uz add-zsh-hook
typeset -ga precmd_functions
source "$test_root/lib/80-languages.zsh"
source "$test_root/functions/development-tools.zsh"

_seed "zsh-${dead_pid}_7"
_seed "444_4" "$old_stamp"
fnm_clean --dry-run --quiet
[[ -L "$ms_dir/zsh-${dead_pid}_7" && -L "$ms_dir/444_4" ]] ||
  _fail "fnm_clean --dry-run removed links"
fnm_clean --quiet
remaining=("$ms_dir"/*(N@:t))
[[ "${(j: :)${(o)remaining}}" == "${(j: :)${(o)expected}}" ]] ||
  _fail "fnm_clean did not apply the staleness rule: ${remaining[*]}"
fnm_clean --all --quiet
remaining=("$ms_dir"/*(N@))
(( ${#remaining} == 0 )) || _fail "fnm_clean --all kept links: ${remaining[*]}"

# fnm keeps links in XDG_RUNTIME_DIR when set (Linux), before XDG_STATE_HOME.
typeset REPLY
XDG_RUNTIME_DIR="$fixture_root/run" _fnm_multishell_dir
[[ "$REPLY" == "$fixture_root/run/fnm_multishells" ]] ||
  _fail "multishell directory ignores XDG_RUNTIME_DIR: $REPLY"

print -r -- "PASS: per-shell fnm links, exit release, and stale-link reaping"

# ============================================================================ #
# End of tests/test-fnm-multishell.zsh
