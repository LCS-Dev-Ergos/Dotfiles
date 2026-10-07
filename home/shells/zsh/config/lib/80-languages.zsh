#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ LANGUAGE INTEGRATION DISPATCHER ++++++++++++++++++++++ #
# ============================================================================ #
# Ordered integrations for native managers and Nix-owned support tools.
# Node queues its PATH rebuild before OCaml finalizes the selected switch.

typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

() {
  local integrations="${${(%):-%x}:A:h:h}/languages"
  local integration
  for integration in \
   platform \
   haskell \
   ocaml \
   jvm \
   python \
   rust \
   cpp \
   conda \
   perl \
   ruby \
   node \
   ocaml-finalize; do
    source "$integrations/$integration.zsh" || return $?
  done
}

# ============================================================================ #
# # End of lib/80-languages.zsh
