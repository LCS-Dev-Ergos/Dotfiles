#!/usr/bin/env zsh
# ============================================================================ #
# ++++++++++++++++++++++ ZSHENV - Environment Variables ++++++++++++++++++++++ #
# ============================================================================ #
#
# This file is sourced for ALL shell types (interactive, non-interactive, login).
# It should ONLY contain environment variable exports - no shell configuration.
#
# Standard Zsh loading order:
#   1. .zshenv     <- YOU ARE HERE (env vars only)
#   2. .zprofile   <- login shells
#   3. .zshrc      <- interactive shells (shell config goes here)
#   4. .zlogin     <- login shells (after .zshrc)
#
# IMPORTANT: Do NOT source .zshrc from here - let Zsh handle the natural flow.
#
# ============================================================================ #

# Profiling is opt-in so regular non-interactive shells pay only two checks.
[[ "${ZSH_PROFILE:-0}" == "1" ]] && zmodload -i zsh/zprof 2>/dev/null
if [[ "${ZSH_STARTUP_TRACE:-0}" == "1" ]] &&
  (( ! $+functions[_zsh_startup_trace_mark] )); then
  typeset _zshenv_config_dir="${${(%):-%x}:A:h}"
  source "$_zshenv_config_dir/startup-trace.zsh"
  unset _zshenv_config_dir
fi
(( $+functions[_zsh_startup_trace_mark] )) &&
  _zsh_startup_trace_mark ".zshenv:entry"

# Keep the multi-user Nix environment available when nix-darwin does not own
# Zsh. The guards make this a no-op while a system initializer still owns it.
typeset _nix_profile_root="/nix/var/nix/profiles/default"
typeset _nix_daemon_env="$_nix_profile_root/etc/profile.d/nix-daemon.sh"
if [[ -z "${NIX_PROFILES:-}" &&
      -z "${__ETC_ZSHENV_SOURCED:-}" &&
      -z "${__NIX_DARWIN_SET_ENVIRONMENT_DONE:-}" &&
      -z "${__ETC_PROFILE_NIX_SOURCED:-}" &&
      -r "$_nix_daemon_env" ]]; then
  source "$_nix_daemon_env"
fi
unset _nix_daemon_env _nix_profile_root

# Expose packages from the active nix-darwin generation in every shell type.
# Keep the system profile after the existing PATH so enabling this integration
# does not unexpectedly replace the currently selected `nix` client. A future
# Home Manager per-user profile takes precedence when it actually exists.
typeset _nix_system_bin="/run/current-system/sw/bin"
typeset _nix_user_bin="${USER:+/etc/profiles/per-user/$USER/bin}"
if [[ -d "$_nix_system_bin" &&
      ":${PATH:-}:" != *":${_nix_system_bin}:"* ]]; then
  export PATH="${PATH:+$PATH:}${_nix_system_bin}"
fi
if [[ -n "$_nix_user_bin" && -d "$_nix_user_bin" &&
      ":${PATH:-}:" != *":${_nix_user_bin}:"* ]]; then
  export PATH="${_nix_user_bin}${PATH:+:$PATH}"
fi
unset _nix_system_bin _nix_user_bin
(( $+functions[_zsh_startup_trace_mark] )) &&
  _zsh_startup_trace_mark ".zshenv:nix"

# Platform detection - load HyDE environment variables on Arch Linux.
# Only env.zsh is loaded here - shell configuration is deferred to .zshrc
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  if [[ "$ID" == "arch" ]]; then
    # HyDE configs stay in the XDG config dir even if we later move ZDOTDIR to $HOME.
    local hyde_cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
    local hyde_env="${hyde_cfg_root}/conf.d/hyde/env.zsh"
    [[ -r "$hyde_env" ]] && source "$hyde_env"
  fi
fi

# Force ZDOTDIR to $HOME so history/dump files live in the home directory
# while the actual configs remain under ${XDG_CONFIG_HOME:-$HOME/.config}/zsh.
export ZDOTDIR="$HOME"

# Expose keg-only Homebrew LLVM (lldb/clang) in ALL shell types, not just
# interactive ones. "brew shellenv" only adds bin/sbin, so without this a
# non-interactive shell (subprocess, IDE build task, debugger) falls back to
# Apple's "/usr/bin/lldb".
if [[ -d "/opt/homebrew/opt/llvm/bin" ]]; then
  export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
fi

# NOTE: .zshrc is loaded automatically by Zsh for interactive shells.
# No explicit sourcing needed here.

(( $+functions[_zsh_startup_trace_mark] )) &&
  _zsh_startup_trace_mark ".zshenv:ready"
:

# ============================================================================ #
# End of ~/.zshenv
