#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ ZFUNCS CATALOG TEST ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies the zfuncs catalog end to end: standard vs. legacy vs. @internal
# classification, hyphenated names, recursive scripts/ discovery, @arg/@option
# synopsis generation, category derivation, styled (plain/ansi/gum) rendering,
# insecure-cache repair, --check failure on legacy metadata, and automatic
# cache invalidation on source changes.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir zfuncs)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap 'command rm -rf -- "$fixture_root"' EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$fixture_root/config/functions" "$fixture_root/config/lib" \
  "$fixture_root/config/scripts/blog" "$fixture_root/cache"
cp "$test_root/scripts/zfuncs-index.awk" "$fixture_root/config/scripts/"
cp "$test_root/scripts/_shared-helpers.zsh" "$fixture_root/config/scripts/"
cp "$test_root/runtime-helpers.zsh" "$fixture_root/config/"

cat > "$fixture_root/config/functions/example.zsh" <<'EOF'
# -----------------------------------------------------------------------------
# alpha
# @description Prints a deterministic value for catalog tests.
# @noargs
# -----------------------------------------------------------------------------
alpha() {
  print -r -- alpha
}

# -----------------------------------------------------------------------------
# hyphen-command
# @description Verifies support for valid function names containing hyphens.
# @noargs
# -----------------------------------------------------------------------------
hyphen-command() {
  return 0
}

# -----------------------------------------------------------------------------
# argcmd
# @description Exercises positional arguments and command-line options.
# @arg $1 string Required input value.
# @arg $2 integer Optional repetition count.
# @option -n | --dry-run Preview the operation.
# -----------------------------------------------------------------------------
argcmd() {
  print -r -- "$@"
}

# -----------------------------------------------------------------------------
# helper
# @internal
# @description Verifies that named implementation helpers remain private.
# @noargs
# -----------------------------------------------------------------------------
helper() {
  return 0
}

# -----------------------------------------------------------------------------
# beta
# Demonstrates compatibility with legacy documentation.
#
# Usage:
#   beta <value>
# -----------------------------------------------------------------------------
beta() {
  print -r -- "$1"
}

# -----------------------------------------------------------------------------
# wide_summary
# @description Verifies that expanded catalog width preserves a long summary
# without losing this distinctive tail marker: retained-at-wide-width.
# @noargs
# -----------------------------------------------------------------------------
wide_summary() {
  return 0
}
EOF

cat > "$fixture_root/config/scripts/blog/commands.zsh" <<'EOF'
# -----------------------------------------------------------------------------
# blog_publish
# @description Publishes a fixture post for recursive catalog tests.
# @noargs
# -----------------------------------------------------------------------------
blog_publish() {
  return 0
}
EOF

export ZSH_CONFIG_DIR="$fixture_root/config"
export XDG_CACHE_HOME="$fixture_root/cache"

source "$fixture_root/config/runtime-helpers.zsh"
source "$test_root/functions/zfuncs.zsh"
source "$fixture_root/config/functions/example.zsh"

typeset listing="$(zfuncs --refresh)"
[[ "$listing" == *alpha*'[loaded]'* ]] || {
  print -u2 "FAIL: standard function missing from listing"
  return 1
}
[[ "$listing" == *hyphen-command*'[loaded]'* ]] || {
  print -u2 "FAIL: hyphenated function missing from listing"
  return 1
}
[[ "$listing" != *beta* ]] || {
  print -u2 "FAIL: legacy function should not appear as registered"
  return 1
}
[[ "$listing" != *helper* ]] || {
  print -u2 "FAIL: @internal function appeared in the public catalog"
  return 1
}
[[ "$listing" == *blog_publish*'[lazy]'* ]] || {
  print -u2 "FAIL: recursively discovered function missing from listing"
  return 1
}

typeset info="$(zfuncs info alpha)"
[[ "$info" == *'Usage:    alpha'* ]] || {
  print -u2 "FAIL: usage missing from info output"
  return 1
}

info="$(zfuncs info hyphen-command)"
[[ "$info" == *'Usage:    hyphen-command'* ]] || {
  print -u2 "FAIL: hyphenated function missing from info output"
  return 1
}
[[ "$info" == *'Category: example'* ]] || {
  print -u2 "FAIL: category missing from info output"
  return 1
}

typeset styled_listing="$(NO_COLOR= ZFUNCS_STYLE=ansi zfuncs)"
[[ "$styled_listing" == *$'\e[1;38;5;212mCUSTOM FUNCTIONS'* ]] || {
  print -u2 "FAIL: ANSI catalog title missing from styled output"
  return 1
}
[[ "$styled_listing" == *$'● loaded'* ]] || {
  print -u2 "FAIL: styled function status missing from catalog"
  return 1
}
[[ "$styled_listing" == *$'─'* ]] || {
  print -u2 "FAIL: styled catalog is missing lightweight separators"
  return 1
}

typeset wide_listing="$(COLUMNS=160 ZFUNCS_STYLE=ansi zfuncs)"
[[ "$wide_listing" == *'retained-at-wide-width.'* ]] || {
  print -u2 "FAIL: wide catalog still truncated available summary space"
  return 1
}

typeset full_width_listing="$(
  COLUMNS=120 ZFUNCS_MAX_WIDTH=80 ZFUNCS_STYLE=plain zfuncs
)"
typeset -a full_width_lines=("${(f)full_width_listing}")
(( ${#full_width_lines[3]} == 120 )) || {
  print -u2 "FAIL: catalog title divider still follows the column width cap"
  return 1
}

typeset styled_info="$(NO_COLOR= ZFUNCS_STYLE=ansi zfuncs info alpha)"
[[ "$styled_info" == *$'\e[1;38;5;212malpha'* ]] || {
  print -u2 "FAIL: ANSI function title missing from styled info output"
  return 1
}
[[ "$styled_info" == *$'\e[1;38;5;81mUsage'* ]] || {
  print -u2 "FAIL: ANSI field labels missing from styled info output"
  return 1
}

if (( $+commands[gum] )); then
  typeset gum_listing="$(NO_COLOR= ZFUNCS_STYLE=gum zfuncs)"
  [[ "$gum_listing" == *'CUSTOM FUNCTIONS'* ]] || {
    print -u2 "FAIL: Gum catalog title is not uppercase"
    return 1
  }
  [[ "$gum_listing" == *$'\e['*'EXAMPLE'* ]] || {
    print -u2 "FAIL: gum category heading is not colored"
    return 1
  }
fi

typeset no_color_listing="$(NO_COLOR=1 ZFUNCS_STYLE=ansi zfuncs)"
[[ "$no_color_listing" != *$'\e['* ]] || {
  print -u2 "FAIL: NO_COLOR did not disable styled output"
  return 1
}

if ZFUNCS_MAX_WIDTH=wide zfuncs >/dev/null 2>&1; then
  print -u2 "FAIL: invalid ZFUNCS_MAX_WIDTH was silently accepted"
  return 1
fi

info="$(zfuncs info argcmd)"
[[ "$info" == *'Usage:    argcmd [options] <$1> [$2]'* ]] || {
  print -u2 "FAIL: shdoc argument metadata produced the wrong synopsis"
  return 1
}

info="$(zfuncs info blog_publish)"
[[ "$info" == *'Category: blog'* ]] || {
  print -u2 "FAIL: nested script category was not derived from its module"
  return 1
}

[[ -f "$fixture_root/cache/zsh/zfuncs/catalog-v1" ]] || {
  print -u2 "FAIL: local catalog was not created"
  return 1
}

cat >> "$fixture_root/config/functions/example.zsh" <<'EOF'

# -----------------------------------------------------------------------------
# gamma
# @description Verifies automatic cache invalidation after a source change.
# @noargs
# -----------------------------------------------------------------------------
gamma() {
  print -r -- gamma
}
EOF
source "$fixture_root/config/functions/example.zsh"
listing="$(zfuncs)"
[[ "$listing" == *gamma*'[loaded]'* ]] || {
  print -u2 "FAIL: source change did not invalidate the catalog"
  return 1
}

chmod 666 "$fixture_root/cache/zsh/zfuncs/catalog-v1"
zfuncs >/dev/null
[[ "$(command stat -f '%Lp' "$fixture_root/cache/zsh/zfuncs/catalog-v1" 2>/dev/null ||
       command stat -c '%a' "$fixture_root/cache/zsh/zfuncs/catalog-v1")" == 600 ]] || {
  print -u2 "FAIL: insecure local catalog was not rebuilt with mode 600"
  return 1
}

if zfuncs --check >/dev/null 2>&1; then
  print -u2 "FAIL: legacy metadata should make validation fail"
  return 1
fi

if command -v shdoc >/dev/null 2>&1; then
  shdoc "$fixture_root/config/functions/example.zsh" >/dev/null
fi

print -r -- "PASS: zfuncs catalog, cache, info, and validation"

# ============================================================================ #
# End of tests/test-zfuncs.zsh
