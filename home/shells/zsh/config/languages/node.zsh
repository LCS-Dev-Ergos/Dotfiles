#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ NODE.JS AND FNM INTEGRATION ++++++++++++++++++++++++ #
# ============================================================================ #

# Node.js and npm defaults apply to every Node process started from the shell,
# before and after the lazy fnm initialization below.
export NPM_CONFIG_FUND=false                    # Disable funding messages.
export NPM_CONFIG_AUDIT=false                   # Disable audit during install.
export NODE_OPTIONS="--max-old-space-size=4096" # Increase V8 heap size.

# Every `fnm env` creates a symlink under fnm_multishells and fnm never removes
# one (Schniz/fnm#696 and #865; no cleanup in any release up to 1.39.0). The
# name fnm gives it, <pid>_<ms>, holds the PID of the short-lived `fnm env`
# process rather than the shell's, so it cannot tell a live link from a stale
# one. Each shell therefore renames its link to zsh-<shell pid>_<ms>, removes
# it on exit, and on start reaps the links of shells that are gone. Links fnm
# named itself (other shells and tools) can only be aged out.
#
# These helpers are defined even without fnm so fnm_clean shares one rule.
typeset -gi _FNM_MULTISHELL_MAX_AGE=604800 # Seven days, for fnm-named links.

# -----------------------------------------------------------------------------
# _fnm_multishell_dir
# @internal
# @description Resolves the directory fnm keeps multishell links in: the
# active link's parent, else fnm's own choice of XDG_RUNTIME_DIR, then
# XDG_STATE_HOME.
# @noargs
# @set REPLY string The multishell directory.
# -----------------------------------------------------------------------------
_fnm_multishell_dir() {
  if [[ -n "${FNM_MULTISHELL_PATH:-}" ]]; then
    REPLY="${FNM_MULTISHELL_PATH:h}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    REPLY="$XDG_RUNTIME_DIR/fnm_multishells"
  else
    REPLY="${XDG_STATE_HOME:-$HOME/.local/state}/fnm_multishells"
  fi
}

# -----------------------------------------------------------------------------
# _fnm_multishell_is_stale
# @internal
# @description Decides whether a multishell link has lost its owner. The
# current shell's link never has. A zsh-<pid>_* link is stale once no process
# of ours holds that PID: kill -0 also fails for another user's process, and a
# shell of ours cannot run as another user. A reused PID only delays removal.
# Any other link is stale once untouched for _FNM_MULTISHELL_MAX_AGE seconds;
# `fnm use` replaces the link, which refreshes its time.
# @arg $1 string Path of the link.
# @exitcode 0 If the link is stale; 1 otherwise.
# -----------------------------------------------------------------------------
_fnm_multishell_is_stale() {
  emulate -L zsh
  local link="$1" name="${1:t}"
  [[ "$link" != "${FNM_MULTISHELL_PATH:-}" ]] || return 1

  if [[ "$name" == zsh-<->_<-> ]]; then
    local pid="${${name#zsh-}%%_*}"
    ! kill -0 "$pid" 2>/dev/null
    return
  fi

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  zmodload zsh/datetime 2>/dev/null || return 1
  local -a mtime
  zstat -L -A mtime +mtime -- "$link" 2>/dev/null || return 1
  (( EPOCHSECONDS - mtime[1] > _FNM_MULTISHELL_MAX_AGE ))
}

# -----------------------------------------------------------------------------
# _fnm_multishell_reap
# @internal
# @description Removes every stale link from the multishell directory.
# @arg $1 string Optional directory; defaults to _fnm_multishell_dir.
# -----------------------------------------------------------------------------
_fnm_multishell_reap() {
  emulate -L zsh
  local REPLY dir="${1:-}" link
  [[ -n "$dir" ]] || { _fnm_multishell_dir; dir="$REPLY"; }
  zmodload -F zsh/files b:zf_rm 2>/dev/null || return 1
  for link in "$dir"/*(N@); do
    _fnm_multishell_is_stale "$link" && zf_rm -f -- "$link"
  done
  return 0
}

# -----------------------------------------------------------------------------
# _fnm_multishell_release
# @internal
# @description zshexit hook that removes the link this shell owns. The hook
# also runs when a subshell exits, so it acts only in the owning process.
# @noargs
# -----------------------------------------------------------------------------
_fnm_multishell_release() {
  [[ -n "${_FNM_OWNED_LINK:-}" ]] || return 0
  zmodload zsh/system 2>/dev/null || return 0
  [[ "${sysparams[pid]}" == "${_FNM_OWNER_PID:-}" ]] || return 0
  zmodload -F zsh/files b:zf_rm 2>/dev/null || return 0
  [[ -L "$_FNM_OWNED_LINK" ]] && zf_rm -f -- "$_FNM_OWNED_LINK"
  return 0
}

# -----------------------------------------------------------------------------
# _fnm_multishell_claim
# @internal
# @description Renames the link `fnm env` just created to zsh-<pid>_<ms>,
# points FNM_MULTISHELL_PATH and PATH at it, arms its removal on exit, and
# reaps stale links. Links already carrying this PID belong to an earlier
# initialization of this shell, or to the shell it replaced with `exec`, which
# kept the PID and ran no exit hook; no other live shell can hold the PID.
# @noargs
# @exitcode 1 If there is no link to claim or it cannot be renamed; the link
# fnm created then stays in use unchanged.
# -----------------------------------------------------------------------------
_fnm_multishell_claim() {
  emulate -L zsh
  local fnm_link="${FNM_MULTISHELL_PATH:-}"
  [[ -n "$fnm_link" && -L "$fnm_link" ]] || return 1
  [[ "$fnm_link" != "${_FNM_OWNED_LINK:-}" ]] || return 0
  zmodload zsh/system zsh/datetime 2>/dev/null || return 1
  zmodload -F zsh/files b:zf_mv b:zf_rm 2>/dev/null || return 1

  local pid="${sysparams[pid]}" dir="${fnm_link:h}" link
  for link in "$dir"/zsh-${pid}_<->(N@); do
    zf_rm -f -- "$link"
  done

  local owned="$dir/zsh-${pid}_${${EPOCHREALTIME/./}[1,13]}"
  zf_mv -- "$fnm_link" "$owned" 2>/dev/null || return 1

  export FNM_MULTISHELL_PATH="$owned"
  local -i index=${path[(Ie)$fnm_link/bin]}
  (( index )) && path[index]="$owned/bin"
  typeset -g _FNM_OWNED_LINK="$owned" _FNM_OWNER_PID="$pid"

  autoload -Uz add-zsh-hook
  add-zsh-hook zshexit _fnm_multishell_release
  _fnm_multishell_reap "$dir"
  return 0
}

if (( $+commands[fnm] )); then
  # ---------------------------------------------------------------------------
  # _fnm_lazy_init
  # @internal
  # @description Initializes the fnm multishell environment once per active
  # symlink, preserves the explicitly selected Node default, claims the new
  # link for this shell, and rebuilds PATH afterward.
  # @noargs
  # @exitcode 1 If `fnm env` fails.
  # ---------------------------------------------------------------------------
  _fnm_lazy_init() {
    if [[ -n "${_FNM_LAZY_INIT:-}" ]]; then
      if [[ -n "${FNM_MULTISHELL_PATH:-}" && -d "$FNM_MULTISHELL_PATH/bin" ]] \
        && [[ ":$PATH:" == *":$FNM_MULTISHELL_PATH/bin:"* ]]; then
        return 0
      fi
      unset _FNM_LAZY_INIT
    fi

    emulate -L zsh
    setopt noxtrace noverbose

    # Global defaults belong to explicit provisioning or `fnm default`.
    # Initialize fnm environment on demand.
    # This sets FNM_MULTISHELL_PATH and adds fnm to PATH.
    local fnm_env_output
    fnm_env_output="$(command fnm env --use-on-cd --shell zsh 2>/dev/null)" || {
      print -u2 "${C_YELLOW}Warning: fnm env failed.${C_RESET}"
      return 1
    }

    if eval "$fnm_env_output"; then
      _FNM_LAZY_INIT=1
      _fnm_multishell_claim

      if typeset -f zsh_rebuild_path >/dev/null 2>&1; then
        zsh_rebuild_path
      fi
      return 0
    fi

    print -u2 "${C_YELLOW}Warning: fnm env failed.${C_RESET}"
    return 1
  }

  if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
    : # skip during fast start.
  elif typeset -f _zsh_defer >/dev/null 2>&1; then
    _zsh_defer _fnm_lazy_init
  else
    add-zsh-hook precmd _fnm_lazy_init
  fi

  # ---------------------------------------------------------------------------
  # fnm
  # @description Initializes fnm on demand, then runs its command.
  # @arg $@ string Arguments forwarded to fnm.
  # ---------------------------------------------------------------------------
  fnm() {
    if ! _fnm_lazy_init; then
      command fnm "$@"
      return $?
    fi
    unfunction fnm 2>/dev/null
    command fnm "$@"
  }

  # Ensure fnm is initialized before each Node-related command.
  # ---------------------------------------------------------------------------
  # node
  # @description Ensures fnm is ready, then runs Node.js.
  # @arg $@ string Arguments forwarded to node.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  node() {
    _fnm_lazy_init || return 1
    command node "$@"
  }

  # ---------------------------------------------------------------------------
  # npm
  # @description Ensures fnm is ready, then runs npm.
  # @arg $@ string Arguments forwarded to npm.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  npm() {
    _fnm_lazy_init || return 1
    command npm "$@"
  }

  # ---------------------------------------------------------------------------
  # npx
  # @description Ensures fnm is ready, then runs npx.
  # @arg $@ string Arguments forwarded to npx.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  npx() {
    _fnm_lazy_init || return 1
    command npx "$@"
  }

  # ---------------------------------------------------------------------------
  # corepack
  # @description Ensures fnm is ready, then runs Corepack.
  # @arg $@ string Arguments forwarded to corepack.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  corepack() {
    _fnm_lazy_init || return 1
    command corepack "$@"
  }

  # ---------------------------------------------------------------------------
  # pi
  # @description Initializes the default fnm Node environment, then launches
  # the Pi coding agent installed in that environment.
  # @arg $@ string Arguments forwarded to Pi.
  # @exitcode 1 If fnm initialization fails; 127 if Pi is not installed.
  # ---------------------------------------------------------------------------
  pi() {
    _fnm_lazy_init || return 1

    local pi_bin="$(whence -p pi 2>/dev/null)"
    if [[ -z "$pi_bin" ]]; then
      print -u2 "pi: executable not found in the active Node environment"
      return 127
    fi

    unfunction pi 2>/dev/null
    "$pi_bin" "$@"
  }
fi

# An unavailable optional integration is a successful no-op.
:
