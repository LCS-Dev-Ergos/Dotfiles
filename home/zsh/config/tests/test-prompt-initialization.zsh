#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ PROMPT INIT TEST +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies lib/30-prompt.zsh: sourcing the module does not activate the prompt
# before the deferred load runs, the Starship init cache is keyed to its
# executable's path, and a valid cache is reused instead of re-running
# Starship.
# ============================================================================ #

setopt errexit nounset pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir prompt-init)" || return 1
typeset cache_file="$fixture_root/cache/zsh/starship-init.zsh"

command mkdir -p "$fixture_root/bin-old" "$fixture_root/bin-new"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP
typeset caller_interrupt_trap
caller_interrupt_trap="$(trap -p INT)"

_make_fake_starship() {
  local executable="$1"
  local marker="$2"
  local counter="$3"
  {
    print -r -- '#!/usr/bin/env zsh'
    print -r -- "print x >> ${(q)counter}"
    print -r -- "print -r -- \"PROMPT='${marker}'\""
    print -r -- "print -r -- \"RPROMPT=''\""
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
[[ "$(trap -p INT)" == "$caller_interrupt_trap" ]] || {
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
[[ "$cache_header" == "# starship-bin: $new_bin" ]] || {
  print -u2 "FAIL: Starship cache does not identify its executable"
  exit 1
}

_zsh_load_starship_init "$new_bin"
(( $(command wc -l < "$old_counter") == 1 &&
   $(command wc -l < "$new_counter") == 1 )) || {
  print -u2 "FAIL: valid Starship init cache was not reused"
  exit 1
}

print "PASS: deferred prompt init, executable-bound cache, and trap isolation"

# ============================================================================ #
# End of tests/test-prompt-initialization.zsh
