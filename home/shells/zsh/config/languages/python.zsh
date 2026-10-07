#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ PYTHON AND PYENV INTEGRATION +++++++++++++++++++++++ #
# ============================================================================ #

if [[ -d "${PYENV_ROOT:-$HOME/.pyenv}" ]]; then
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"

  if command -v pyenv >/dev/null 2>&1; then
    # -------------------------------------------------------------------------
    # _pyenv_lazy_init
    # @internal
    # @description Evaluates pyenv init and virtualenv-init once, guarded
    # against re-running.
    # @noargs
    # -------------------------------------------------------------------------
    _pyenv_lazy_init() {
      [[ -n "${_PYENV_LAZY_INIT:-}" ]] && return 0
      _PYENV_LAZY_INIT=1
      eval "$(command pyenv init -)" 2>/dev/null || print -u2 "${C_YELLOW}Warning: pyenv init failed.${C_RESET}"
      eval "$(command pyenv virtualenv-init -)" 2>/dev/null || print -u2 "${C_YELLOW}Warning: pyenv virtualenv-init failed.${C_RESET}"
    }

    # -------------------------------------------------------------------------
    # pyenv
    # @description Lazily initializes pyenv, then runs its command.
    # @arg $@ string Arguments forwarded to pyenv.
    # -------------------------------------------------------------------------
    pyenv() {
      unfunction pyenv 2>/dev/null
      _pyenv_lazy_init
      pyenv "$@"
    }
  fi
fi

# Python: Bytecode caching and pip best practices.
export PYTHONDONTWRITEBYTECODE=1   # Avoid .pyc files cluttering directories.
export PIP_REQUIRE_VIRTUALENV=true # Safety: only allow pip in virtual environments.
export PIPENV_VENV_IN_PROJECT=1    # Store .venv in project directory.

# An unavailable optional integration is a successful no-op.
:
