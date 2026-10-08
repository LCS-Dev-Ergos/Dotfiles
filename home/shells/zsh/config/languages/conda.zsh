#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ CONDA INTEGRATION +++++++++++++++++++++++++++++ #
# ============================================================================ #

# >>> Conda initialize >>>
# -----------------------------------------------------------------------------
# _conda_lazy_init
# @internal
# @description Initializes Conda/Miniforge once, guarded against re-running,
# checking the Arch system path and the user Miniforge install in turn, and
# disabling conda's own prompt modification.
# @noargs
# -----------------------------------------------------------------------------
_conda_lazy_init() {
  [[ -n "${_CONDA_LAZY_INIT:-}" ]] && return 0
  _CONDA_LAZY_INIT=1

  local conda_path=""
  # Arch specific path.
  if [[ "$PLATFORM" == 'Linux' && -f "/opt/miniconda3/bin/conda" ]]; then
    conda_path="/opt/miniconda3/bin/conda"
    # User path (macOS or other Linux); CONDA_ROOT_PREFIX is conda's own name
    # for the base prefix, which the bootstrap also installs Miniforge into.
  elif [[ -f "${CONDA_ROOT_PREFIX:-$HOME/.miniforge3}/bin/conda" ]]; then
    conda_path="${CONDA_ROOT_PREFIX:-$HOME/.miniforge3}/bin/conda"
  fi

  if [[ -n "$conda_path" ]]; then
    __conda_setup="$("$conda_path" 'shell.zsh' 'hook' 2>/dev/null)"
    if [[ $? -eq 0 ]]; then
      eval "$__conda_setup"
    else
      local conda_dir
      conda_dir=$(dirname "$(dirname "$conda_path")")
      if [[ -f "$conda_dir/etc/profile.d/conda.sh" ]]; then
        . "$conda_dir/etc/profile.d/conda.sh"
      else
        export PATH="$(dirname "$conda_path"):$PATH"
      fi
    fi
    unset __conda_setup

    # Disable conda's built-in prompt modification (runs on first use only).
    conda config --set changeps1 false 2>/dev/null
  fi
}

if [[ -f "/opt/miniconda3/bin/conda" ||
      -f "${CONDA_ROOT_PREFIX:-$HOME/.miniforge3}/bin/conda" ]]; then
  # ---------------------------------------------------------------------------
  # conda
  # @description Lazily initializes Conda, then runs its command.
  # @arg $@ string Arguments forwarded to conda.
  # ---------------------------------------------------------------------------
  conda() {
    unfunction conda 2>/dev/null
    _conda_lazy_init
    conda "$@"
  }
fi
# <<< Conda initialize <<<

# An unavailable optional integration is a successful no-op.
:
