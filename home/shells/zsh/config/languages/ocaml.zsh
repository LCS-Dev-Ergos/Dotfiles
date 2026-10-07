#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ OCAML AND OPAM INTEGRATION ++++++++++++++++++++++++ #
# ============================================================================ #

# OCaml: Build and package manager optimization.
export OPAMJOBS="${_ZSH_NCPUS:-4}"           # Parallel builds.
export DUNE_CACHE=enabled-except-user-rules  # Avoid caching unsafe custom rules.
export DUNE_CACHE_TRANSPORT=direct           # Faster cache access.
# export OPAMYES=1  # Auto-confirm opam operations.

[[ ! -r "${OPAMROOT:-$HOME/.opam}/opam-init/init.zsh" ]] ||
  source "${OPAMROOT:-$HOME/.opam}/opam-init/init.zsh" >/dev/null 2>/dev/null

# opam's shell hook runs `opam env` (about 30 ms) before every prompt. The
# environment it computes only changes with the directory (local `_opam`
# switches), the root, the global switch in the opam config, or OPAMSWITCH, so
# the replacement below checks those with a single stat and calls opam only
# when one of them moved. It keeps the hook's position among precmd hooks.
if (( ${precmd_functions[(Ie)_opam_env_hook]} )); then
  typeset -g _ZSH_OPAM_ENV_STAMP=""

  # ---------------------------------------------------------------------------
  # _zsh_opam_env_stamp
  # @internal
  # @description Describes the inputs of `opam env` for the current shell.
  # @noargs
  # @set REPLY string Directory, opam root, config mtime, and OPAMSWITCH.
  # ---------------------------------------------------------------------------
  _zsh_opam_env_stamp() {
    local -a config_mtime
    zstat -A config_mtime +mtime -- \
      "${OPAMROOT:-$HOME/.opam}/config" 2>/dev/null || config_mtime=(0)
    REPLY="$PWD|${OPAMROOT:-$HOME/.opam}|${config_mtime[1]}|${OPAMSWITCH-}"
  }

  # ---------------------------------------------------------------------------
  # _zsh_opam_env_hook
  # @internal
  # @description Re-applies `opam env` when its inputs changed since the
  # last run; the precmd replacement for opam's unconditional hook.
  # @noargs
  # ---------------------------------------------------------------------------
  _zsh_opam_env_hook() {
    local REPLY
    _zsh_opam_env_stamp
    [[ "$REPLY" == "$_ZSH_OPAM_ENV_STAMP" ]] && return 0
    _zsh_opam_env_apply || return $?
    _ZSH_OPAM_ENV_STAMP="$REPLY"
  }

  # ---------------------------------------------------------------------------
  # _zsh_opam_env_apply
  # @internal
  # @description Evaluates `opam env` for the current directory and switch.
  # @noargs
  # ---------------------------------------------------------------------------
  _zsh_opam_env_apply() {
    local opam_env
    opam_env="$(command opam env --shell=zsh --readonly 2>/dev/null </dev/null)" || {
      local result=$?
      _ZSH_OPAM_ENV_STAMP=""
      return "$result"
    }
    eval "$opam_env" || {
      local result=$?
      _ZSH_OPAM_ENV_STAMP=""
      return "$result"
    }
  }

  if zmodload -F zsh/stat b:zstat 2>/dev/null; then
    # Reloads may leave our replacement beside the upstream hook. Preserve
    # the first hook's position and keep exactly one environment update.
    () {
      local hook
      local -i inserted=0
      local -a hooks=()
      for hook in "${precmd_functions[@]}"; do
        if [[ "$hook" == _opam_env_hook || "$hook" == _zsh_opam_env_hook ]]; then
          (( inserted )) || hooks+=(_zsh_opam_env_hook)
          inserted=1
        else
          hooks+=("$hook")
        fi
      done
      precmd_functions=("${hooks[@]}")
    }
  fi
  # The first run is scheduled at the end of this file.
fi

# An unavailable optional integration is a successful no-op.
:
