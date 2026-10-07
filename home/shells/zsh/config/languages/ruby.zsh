#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ RUBY AND RBENV INTEGRATION ++++++++++++++++++++++++ #
# ============================================================================ #

if [[ -d "${RBENV_ROOT:-$HOME/.rbenv}" ]]; then
  export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
  [[ -d "$RBENV_ROOT/bin" ]] && export PATH="$RBENV_ROOT/bin:$PATH"

  if command -v rbenv >/dev/null 2>&1; then
    # -------------------------------------------------------------------------
    # _rbenv_lazy_init
    # @internal
    # @description Evaluates rbenv init once, guarded against re-running.
    # @noargs
    # -------------------------------------------------------------------------
    _rbenv_lazy_init() {
      [[ -n "${_RBENV_LAZY_INIT:-}" ]] && return 0
      _RBENV_LAZY_INIT=1
      eval "$(command rbenv init - zsh)" 2>/dev/null || print -u2 "${C_YELLOW}Warning: rbenv init failed.${C_RESET}"
    }

    # -------------------------------------------------------------------------
    # rbenv
    # @description Lazily initializes rbenv, then runs its command.
    # @arg $@ string Arguments forwarded to rbenv.
    # -------------------------------------------------------------------------
    rbenv() {
      unfunction rbenv 2>/dev/null
      _rbenv_lazy_init
      rbenv "$@"
    }
  fi
fi

# An unavailable optional integration is a successful no-op.
:
