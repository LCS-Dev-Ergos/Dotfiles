#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++ PLATFORM AND NATIVE MANAGER INTEGRATION ++++++++++++++++++ #
# ============================================================================ #

# ~/.zshenv (zshenv-bootstrap) already exports the Apple Silicon prefix for
# every shell. This covers the prefixes it does not handle (Intel macOS and
# Linuxbrew) without prepending the same MANPATH/INFOPATH entries twice.
if [[ -n "${HOMEBREW_PREFIX:-}" ]]; then
  # Login shells run /etc/zprofile after ~/.zshenv, and its path_helper moves
  # the system man pages ahead of Homebrew's. Put Homebrew's back in front,
  # once, so `man` prefers the same (newer) tools that PATH does.
  [[ -d "$HOMEBREW_PREFIX/share/man" ]] && manpath=(
    "$HOMEBREW_PREFIX/share/man"
    "${(@)manpath:#$HOMEBREW_PREFIX/share/man}"
  )
elif [[ "$PLATFORM" == 'macOS' ]]; then
  # On macOS, check for the Apple Silicon path first, then the Intel path.
  if [[ -x "/opt/homebrew/bin/brew" ]]; then # macOS Apple Silicon
    export HOMEBREW_PREFIX="/opt/homebrew"
    export HOMEBREW_CELLAR="/opt/homebrew/Cellar"
    export HOMEBREW_REPOSITORY="/opt/homebrew"
    export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
    export MANPATH="/opt/homebrew/share/man${MANPATH:+:$MANPATH}"
    export INFOPATH="/opt/homebrew/share/info${INFOPATH:+:$INFOPATH}"
  elif [[ -x "/usr/local/bin/brew" ]]; then # macOS Intel
    export HOMEBREW_PREFIX="/usr/local"
    export HOMEBREW_CELLAR="/usr/local/Cellar"
    export HOMEBREW_REPOSITORY="/usr/local/Homebrew"
    export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
    export MANPATH="/usr/local/share/man${MANPATH:+:$MANPATH}"
    export INFOPATH="/usr/local/share/info${INFOPATH:+:$INFOPATH}"
  fi
elif [[ "$PLATFORM" == 'Linux' ]]; then
  # On Linux, check for the standard Linuxbrew path.
  if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
    export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
    export HOMEBREW_CELLAR="/home/linuxbrew/.linuxbrew/Cellar"
    export HOMEBREW_REPOSITORY="/home/linuxbrew/.linuxbrew/Homebrew"
    export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
    export MANPATH="/home/linuxbrew/.linuxbrew/share/man${MANPATH:+:$MANPATH}"
    export INFOPATH="/home/linuxbrew/.linuxbrew/share/info${INFOPATH:+:$INFOPATH}"
  fi
fi

# Upstream FNM on native Linux hosts is a standalone executable beside its
# runtime data. Expose it before node.zsh checks command availability. The
# migration checkpoint prevents it from replacing the temporary Nix owner.
if [[ "${LCS_RUNTIME_MANAGER_BACKEND:-}" == native &&
      "${LCS_NATIVE_FNM_READY:-}" == 1 ]]; then
  () {
    local fnm_root="${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}"
    [[ -x "$fnm_root/fnm" ]] || return 0
    path=("$fnm_root" "${(@)path:#$fnm_root}")
  }
fi

# An unavailable optional integration is a successful no-op.
:
