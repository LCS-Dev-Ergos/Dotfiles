#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ PERL INTEGRATION +++++++++++++++++++++++++++++ #
# ============================================================================ #

# Static, idempotent equivalent of `eval "$(perl -Mlocal::lib=~/.perl5)"`.
# The perl form prints only what the current environment still lacks, so its
# output cannot be cached safely, and running it costs a perl start per shell.
# Nested shells keep a single copy of each entry;
# 90-path.zsh places ~/.perl5/bin in PATH.
if [[ -d "$HOME/.perl5" ]]; then
  () {
    local root="$HOME/.perl5"
    local -a libs=("${(@s/:/)PERL5LIB}") roots=("${(@s/:/)PERL_LOCAL_LIB_ROOT}")
    libs=("$root/lib/perl5" "${(@)libs:#($root/lib/perl5|)}")
    roots=("$root" "${(@)roots:#($root|)}")
    export PERL5LIB="${(j/:/)libs}"
    export PERL_LOCAL_LIB_ROOT="${(j/:/)roots}"
    export PERL_MB_OPT="--install_base \"$root\""
    export PERL_MM_OPT="INSTALL_BASE=$root"
  }
fi

# An unavailable optional integration is a successful no-op.
:
