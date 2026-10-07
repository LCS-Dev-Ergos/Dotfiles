#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++ OCAML DEFERRED ENVIRONMENT FINALIZATION ++++++++++++++++++ #
# ============================================================================ #

# "variables.sh" (sourced in the Opam section) already applied the global switch,
# so the stamp is seeded and the first prompt skips opam. One idle-time run still
# finishes what opam's own hook did there: it moves the switch's bin to the front
# of PATH and records OPAM_LAST_ENV, which later switch changes revert against.
# It is queued here, after _fnm_lazy_init, because that task rebuilds PATH and
# would undo the order again. A start directory inside a local switch keeps the
# synchronous first run, since the global environment is wrong there.
if (( ${precmd_functions[(Ie)_zsh_opam_env_hook]} && $+functions[_zsh_defer] )); then
  () {
    local dir="$PWD"
    while [[ -n "$dir" ]]; do
      [[ -d "$dir/_opam" ]] && return 0
      dir="${dir%/*}"
    done
    local REPLY
    _zsh_opam_env_stamp
    _ZSH_OPAM_ENV_STAMP="$REPLY"
    _zsh_defer _zsh_opam_env_apply
  }
fi

# An unavailable optional integration is a successful no-op.
:
