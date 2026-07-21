#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ FABRIC TOOLS TEST +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies _fabric_lazy_init in lib/70-ai-tools.zsh: patterns are namespaced
# under fabric-pattern/fabric-update/fabric-list rather than polluting the
# global function namespace, directory- and legacy flat-file patterns are
# both discovered, a failed Fabric run leaves no partial Obsidian note, a
# successful run publishes one atomically with mode 600 and no leftover temp
# files, and reloads replace module-owned wrappers without clobbering
# user-defined functions.
# ============================================================================ #

emulate -L zsh
setopt pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir fabric)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap 'command rm -rf -- "$fixture_root"' EXIT
trap 'exit 130' INT TERM HUP

mkdir -p \
  "$fixture_root/bin" \
  "$fixture_root/home/.config/fabric/patterns/summarize" \
  "$fixture_root/home/.config/fabric/patterns/print"

cat > "$fixture_root/bin/fabric-ai" <<'EOF'
#!/bin/sh
printf 'mock response: %s\n' "$*"
exit "${FABRIC_TEST_EXIT:-0}"
EOF
chmod 700 "$fixture_root/bin/fabric-ai"

print -r -- "fixture" > \
  "$fixture_root/home/.config/fabric/patterns/summarize/system.md"
print -r -- "fixture" > \
  "$fixture_root/home/.config/fabric/patterns/print/system.md"
print -r -- "legacy fixture" > \
  "$fixture_root/home/.config/fabric/patterns/legacy_pattern"
touch "$fixture_root/home/.config/fabric/patterns/loaded"

export HOME="$fixture_root/home"
export PATH="$fixture_root/bin:$PATH"
export ZSH_FAST_START=1
unset FABRIC_OUTPUT_DIR

source "$test_root/lib/70-ai-tools.zsh"

typeset -f summarize >/dev/null 2>&1 && {
  print -u2 "FAIL: Fabric pattern polluted the global function namespace"
  return 1
}
typeset -f legacy_pattern >/dev/null 2>&1 && {
  print -u2 "FAIL: legacy Fabric pattern polluted the function namespace"
  return 1
}
typeset -f loaded >/dev/null 2>&1 && {
  print -u2 "FAIL: Fabric marker file was registered as a pattern"
  return 1
}
typeset -f print >/dev/null 2>&1 && {
  print -u2 "FAIL: Fabric pattern shadowed an existing builtin"
  return 1
}

_fabric_pattern_names
(( ${reply[(Ie)summarize]} )) || {
  print -u2 "FAIL: directory-based Fabric pattern was not discovered"
  return 1
}
(( ${reply[(Ie)legacy_pattern]} )) || {
  print -u2 "FAIL: legacy flat-file Fabric pattern was not discovered"
  return 1
}
(( ${reply[(Ie)print]} )) || {
  print -u2 "FAIL: namespaced pattern discovery rejected a builtin name"
  return 1
}
(( ${reply[(Ie)loaded]} == 0 )) || {
  print -u2 "FAIL: Fabric marker file was exposed as a pattern"
  return 1
}

typeset list_output
list_output="$(fabric-pattern --list)" || {
  print -u2 "FAIL: namespaced pattern listing failed"
  return 1
}
[[ "$list_output" == *--listpatterns* ]] || {
  print -u2 "FAIL: Fabric listing used an obsolete backend flag"
  return 1
}

typeset update_output
if ! fabric-update > "$fixture_root/update.stdout"; then
  print -u2 "FAIL: Fabric pattern update failed"
  return 1
fi
update_output="$(< "$fixture_root/update.stdout")"
[[ "$update_output" == *--updatepatterns* ]] || {
  print -u2 "FAIL: Fabric update used an obsolete backend flag"
  return 1
}
(( _FABRIC_PATTERN_CACHE_READY == 0 )) || {
  print -u2 "FAIL: Fabric update did not invalidate pattern discovery"
  return 1
}

typeset stream_output
stream_output="$(fabric-pattern legacy_pattern)" || {
  print -u2 "FAIL: namespaced legacy pattern execution failed"
  return 1
}
[[ "$stream_output" == *"--pattern legacy_pattern --stream"* ]] || {
  print -u2 "FAIL: namespaced streaming arguments are incorrect"
  return 1
}

if fabric-pattern missing_pattern >/dev/null 2>&1; then
  print -u2 "FAIL: unknown Fabric pattern reached the backend"
  return 1
fi

typeset output_dir="$FABRIC_OUTPUT_DIR"
typeset date_stamp="$(date +'%Y-%m-%d')"
typeset failed_note="$output_dir/${date_stamp}-Failed Note.md"
typeset successful_note="$output_dir/${date_stamp}-Successful Note.md"
typeset -i fabric_rc=0

export FABRIC_TEST_EXIT=7
fabric-pattern summarize "Failed Note" \
  >/dev/null 2> "$fixture_root/failure.stderr" ||
  fabric_rc=$?
(( fabric_rc == 7 )) || {
  print -u2 "FAIL: Fabric failure status was not preserved"
  return 1
}
[[ ! -e "$failed_note" ]] || {
  print -u2 "FAIL: failed Fabric run published an Obsidian note"
  return 1
}
[[ "$(< "$fixture_root/failure.stderr")" == *'no note was saved'* ]] || {
  print -u2 "FAIL: Fabric failure did not report transactional rollback"
  return 1
}

export FABRIC_TEST_EXIT=0
typeset success_output
success_output="$(fabric-pattern summarize "Successful Note")" || {
  print -u2 "FAIL: successful Fabric run returned an error"
  return 1
}
[[ "$success_output" == *"Saved to: $successful_note"* ]] || {
  print -u2 "FAIL: successful Fabric run did not report the saved note"
  return 1
}
[[ -f "$successful_note" ]] || {
  print -u2 "FAIL: successful Fabric run did not publish its note"
  return 1
}
rg -q '^pattern: summarize$' "$successful_note" || {
  print -u2 "FAIL: published note is missing Fabric frontmatter"
  return 1
}
rg -q '^mock response: --pattern summarize$' "$successful_note" || {
  print -u2 "FAIL: published note is missing the Fabric response"
  return 1
}

typeset note_mode
note_mode="$(
  command stat -f '%Lp' "$successful_note" 2>/dev/null ||
    command stat -c '%a' "$successful_note"
)"
[[ "$note_mode" == 600 ]] || {
  print -u2 "FAIL: published Fabric note permissions are not 600"
  return 1
}

typeset -a leftovers=("$output_dir"/.fabric-*(N))
(( ${#leftovers[@]} == 0 )) || {
  print -u2 \
    "FAIL: Fabric transaction left temporary files behind: ${leftovers[*]}"
  return 1
}

# A reload must remove a wrapper tracked by the legacy implementation.
typeset legacy_body='_fabric_run_pattern legacy_pattern "$@"'
functions[legacy_pattern]="$legacy_body"
typeset -gA _FABRIC_PATTERN_WRAPPERS
_FABRIC_PATTERN_WRAPPERS[legacy_pattern]="$legacy_body"
source "$test_root/lib/70-ai-tools.zsh"
typeset -f legacy_pattern >/dev/null 2>&1 && {
  print -u2 "FAIL: Fabric reload retained a module-owned legacy wrapper"
  return 1
}

# A user replacement of a previously generated name must survive reloads.
functions[summarize]='print -r -- user-defined'
typeset -gA _FABRIC_PATTERN_WRAPPERS
_FABRIC_PATTERN_WRAPPERS[summarize]='_fabric_run_pattern summarize "$@"'
source "$test_root/lib/70-ai-tools.zsh"
[[ "${functions[summarize]}" == *user-defined* ]] || {
  print -u2 "FAIL: Fabric reload overwrote a user-defined function"
  return 1
}

print -r -- "PASS: Fabric namespace, discovery, and atomic notes"

# ============================================================================ #
# End of tests/test-fabric-tools.zsh
