#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ PROMPT INIT TEST +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies lib/30-prompt.zsh: sourcing the module does not activate the prompt
# before the deferred load runs, the Starship init cache is keyed to its
# executable's path, a valid cache is reused instead of re-running Starship,
# the continuation prompt is left for prompt expansion to compute, and the
# right-aligned kitty layout is chosen only where kitty redraws the prompt.
# ============================================================================ #

setopt errexit nounset pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir prompt-init)" || return 1
typeset cache_file="$fixture_root/cache/zsh/init-starship.zsh"

command mkdir -p "$fixture_root/bin-old" "$fixture_root/bin-new"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP
typeset caller_interrupt_trap
caller_interrupt_trap="$(trap)"

_make_fake_starship() {
  local executable="$1"
  local marker="$2"
  local counter="$3"
  {
    print -r -- '#!/usr/bin/env zsh'
    print -r -- "print x >> ${(q)counter}"
    print -r -- "print -r -- \"PROMPT='${marker}'\""
    print -r -- "print -r -- \"RPROMPT=''\""
    print -r -- "print -r -- 'PROMPT2=\"\$(print -r -- cont-${marker})\"'"
  } >| "$executable"
  command chmod 700 "$executable"
}

typeset old_bin="$fixture_root/bin-old/starship"
typeset new_bin="$fixture_root/bin-new/starship"
typeset old_counter="$fixture_root/old.count"
typeset new_counter="$fixture_root/new.count"
_make_fake_starship "$old_bin" old-prompt "$old_counter"
_make_fake_starship "$new_bin" new-prompt "$new_counter"
command touch -t 202001010000 "$old_bin" "$new_bin"

export XDG_CACHE_HOME="$fixture_root/cache"
typeset HYDE_ENABLED=0
typeset HYDE_ZSH_PROMPT=0
PROMPT=sentinel
source "$test_root/lib/30-prompt.zsh"

if [[ "$PROMPT" != sentinel ]]; then
  print -u2 "FAIL: sourcing 30-prompt.zsh activated the prompt too early"
  exit 1
fi

_zsh_load_starship_init "$old_bin"
[[ "$PROMPT" == old-prompt ]] || {
  print -u2 "FAIL: initial Starship executable was not evaluated"
  exit 1
}
[[ "$PROMPT2" == '$(print -r -- cont-old-prompt)' ]] || {
  print -u2 "FAIL: the continuation prompt was evaluated at startup"
  exit 1
}
[[ "$(trap)" == "$caller_interrupt_trap" ]] || {
  print -u2 "FAIL: atomic cache writing replaced the caller's signal trap"
  exit 1
}

_zsh_load_starship_init "$new_bin"
[[ "$PROMPT" == new-prompt ]] || {
  print -u2 "FAIL: Starship cache survived an executable-path change"
  exit 1
}

typeset cache_header
IFS= read -r cache_header < "$cache_file"
[[ "$cache_header" == "# init-cache-v1 ${new_bin:A} init zsh"* ]] || {
  print -u2 "FAIL: Starship cache does not identify its executable"
  exit 1
}

_zsh_load_starship_init "$new_bin"
(( $(command wc -l < "$old_counter") == 1 &&
   $(command wc -l < "$new_counter") == 1 )) || {
  print -u2 "FAIL: valid Starship init cache was not reused"
  exit 1
}

path=("$fixture_root/bin-new" $path)
TRAPINT() { return 130; }
typeset prompt_interrupt_handler="${functions[TRAPINT]}"
_init_starship_prompt
_tp_precmd
_tp_precmd
[[ "${functions[TRAPINT]}" == "$prompt_interrupt_handler" ]] || {
  print -u2 "FAIL: transient prompt replaced the caller's interrupt handler"
  exit 1
}

_tp_zle_line_finish
(( _tp_fd == 0 )) || {
  print -u2 "FAIL: transient prompt opened a descriptor outside ZLE"
  exit 1
}

# Simulate a reload while the one-shot callback is still pending.
sysopen -r -o cloexec -u _tp_fd /dev/null
zle -F "$_tp_fd" _tp_restore_prompt
typeset pending_fd=$_tp_fd
_init_starship_prompt
(( _tp_fd == 0 )) && [[ ! -e /dev/fd/$pending_fd ]] || {
  print -u2 "FAIL: prompt reload leaked its pending descriptor"
  exit 1
}

# A failed engine load must restore another owner's existing widget.
_fixture_keymap() { return 0; }
zle -N zle-keymap-select _fixture_keymap
if _zsh_load_starship_init "$fixture_root/missing-starship" 2>/dev/null; then
  print -u2 "FAIL: missing Starship was accepted"
  exit 1
fi
[[ "${widgets[zle-keymap-select]}" == user:_fixture_keymap ]] || {
  print -u2 "FAIL: failed Starship init lost the previous keymap widget"
  exit 1
}

# The right-aligned variant is only for kitty's own prompt redraw: a pane of a
# multiplexer inherits kitty's variables but is re-wrapped by the multiplexer.
_ksi_precmd() { :; }
_prompt_layout() {
  ( eval "$1"; _zsh_prompt_redrawn_by_kitty ) && print kitty || print one-line
}
typeset layout_case
for layout_case in \
    'TERM=xterm-kitty TMUX= ZELLIJ= STY= HERDR_ENV=:kitty' \
    'TERM=xterm-kitty HERDR_ENV=1:one-line' \
    'TERM=xterm-kitty TMUX=/tmp/tmux-1/default:one-line' \
    'TERM=xterm-256color TMUX= HERDR_ENV=:one-line' \
    'TERM=xterm-kitty TMUX= HERDR_ENV= KITTY_SHELL_INTEGRATION=no-prompt-mark:one-line' \
    'TERM=xterm-kitty TMUX= HERDR_ENV=; unfunction _ksi_precmd:one-line'; do
  [[ "$(_prompt_layout "${layout_case%:*}")" == "${layout_case##*:}" ]] || {
    print -u2 "FAIL: wrong prompt layout for: ${layout_case%:*}"
    exit 1
  }
done
unfunction _ksi_precmd _prompt_layout

print "PASS: deferred prompt init, executable-bound cache, trap and hook isolation, layout choice"

# ============================================================================ #
# End of tests/test-prompt-initialization.zsh
