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
typeset _nix_user_profile=""
if [[ -n "${USER:-}" && -d "/etc/profiles/per-user/$USER" ]]; then
  _nix_user_profile="/etc/profiles/per-user/$USER"
elif [[ -n "${HOME:-}" && -d "$HOME/.nix-profile" ]]; then
  _nix_user_profile="$HOME/.nix-profile"
fi
typeset _nix_user_bin="${_nix_user_profile:+$_nix_user_profile/bin}"
if [[ -d "$_nix_system_bin" &&
      ":${PATH:-}:" != *":${_nix_system_bin}:"* ]]; then
  export PATH="${PATH:+$PATH:}${_nix_system_bin}"
fi
if [[ -n "$_nix_user_bin" && -d "$_nix_user_bin" &&
      ":${PATH:-}:" != *":${_nix_user_bin}:"* ]]; then
  export PATH="${_nix_user_bin}${PATH:+:$PATH}"
fi

# The custom Zsh deployment deliberately leaves programs.zsh disabled, so it
# must source Home Manager's standard session-variable file itself. This keeps
# immutable package paths such as CC/CXX available to non-interactive shells.
# The canonical-path check is the explicit exception to the user-owned-source
# rule: profile links are trusted only when they resolve into the Nix store.
typeset _hm_session_vars="${_nix_user_profile:+$_nix_user_profile/etc/profile.d/hm-session-vars.sh}"
typeset _hm_session_vars_target="${_hm_session_vars:A}"
if [[ -r "$_hm_session_vars_target" &&
      "$_hm_session_vars_target" == /nix/store/* ]]; then
  source "$_hm_session_vars_target"
fi
unset _hm_session_vars _hm_session_vars_target
unset _nix_system_bin _nix_user_bin _nix_user_profile
(( $+functions[_zsh_startup_trace_mark] )) &&
  _zsh_startup_trace_mark ".zshenv:nix"

# Platform detection - load HyDE environment variables on Arch Linux.
# Only env.zsh is loaded here - shell configuration is deferred to .zshrc.
# /etc/arch-release is the same probe runtime-helpers.zsh uses; sourcing
# /etc/os-release instead would leave NAME, ID, VERSION, ... behind as
# globals in every shell, scripts included.
if [[ -f /etc/arch-release ]]; then
  # HyDE configs stay in the XDG config dir even if we later move ZDOTDIR to $HOME.
  typeset _hyde_env="${XDG_CONFIG_HOME:-$HOME/.config}/zsh/conf.d/hyde/env.zsh"
  [[ -r "$_hyde_env" ]] && source "$_hyde_env"
  unset _hyde_env
fi

# Apple's /etc/zshrc spends a `locale` fork on every interactive shell for
# settings this configuration owns anyway (history, key bindings, prompt);
# lib/00-initialization.zsh keeps the rest of it without the fork. GLOBAL_RCS
# must be decided here, before /etc/zshrc runs. Login shells still need
# /etc/zprofile, whose path_helper builds the system PATH, so ~/.zprofile
# turns the option off for them only after that. A symlinked /etc/zshrc is
# nix-darwin's (programs.zsh), which is never skipped.
if [[ "$OSTYPE" == darwin* && -o interactive && ! -o login &&
      ! -L /etc/zshrc ]]; then
  unsetopt GLOBAL_RCS
fi

# Keep Zsh's root control files and history in $HOME. Completion dumps and
# generated runtime data are configured separately below XDG cache/state paths,
# while application configuration remains under XDG_CONFIG_HOME.
export ZDOTDIR="$HOME"

# NOTE: .zshrc is loaded automatically by Zsh for interactive shells.
# No explicit sourcing needed here.

(( $+functions[_zsh_startup_trace_mark] )) &&
  _zsh_startup_trace_mark ".zshenv:ready"
:

# ============================================================================ #
# End of ~/.zshenv
