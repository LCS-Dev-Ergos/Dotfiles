#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#                      ███████╗██╗███╗   ██╗██╗████████╗
#                      ╚══███╔╝██║████╗  ██║██║╚══██╔══╝
#                        ███╔╝ ██║██╔██╗ ██║██║   ██║
#                       ███╔╝  ██║██║╚██╗██║██║   ██║
#                      ███████╗██║██║ ╚████║██║   ██║
#                      ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝
# ============================================================================ #
# +++++++++++++++++++++++++++++++ ZINIT SETUP ++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Zinit-based plugin loading that replaces the Oh-My-Zsh framework bootstrap.
# Keep startup synchronous work small and shift non-critical plugins to turbo.
#
# ============================================================================ #

typeset -f _zsh_mtime >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

# On HyDE: this file is loaded only when "HYDE_ZSH_NO_PLUGINS=1".
# The guard below is a safety net for direct sourcing.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
  # HyDE's shell.zsh handles plugins instead.
  return 0
fi

# Keep compfix (compaudit) enabled by default for safer completion loading.
# Set to "true" only if you explicitly want to skip security checks.
: "${ZSH_DISABLE_COMPFIX:=false}"
: "${ZSH_ENABLE_YOU_SHOULD_USE:=0}"
: "${ZSH_COMPINIT_CHECK_HOURS:=24}"
: "${ZSH_ENABLE_ZSH_COMPLETIONS:=1}"
: "${ZSH_ENABLE_FZF_TAB:=1}"
: "${ZSH_ENABLE_BREW_COMMAND_NOT_FOUND:=0}"

# Install and source Zinit from XDG data directory.
typeset -g ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"
if [[ ! -f "$ZINIT_HOME/zinit.zsh" ]]; then
  command mkdir -p "$ZINIT_HOME:h" 2>/dev/null
  if command -v git >/dev/null 2>&1; then
    if ! command git clone --depth=1 https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME" >/dev/null 2>&1; then
      print -u2 "Warning: failed to clone zinit repository into $ZINIT_HOME"
    fi
  fi
fi

if [[ ! -f "$ZINIT_HOME/zinit.zsh" ]]; then
  # Fall back to the Oh-My-Zsh profile when Zinit isn't available
  # (offline/first boot). It lives in others/, beside lib/, so the startup
  # glob never loads it on its own.
  typeset _zinit_omz_backup="${${(%):-%x}:A:h:h}/others/20-omz-fallback.zsh"
  if [[ "${ZSH_ZINIT_FALLBACK_OMZ:-1}" == "1" ]] && [[ -r "$_zinit_omz_backup" ]]; then
    print -u2 \
      "Warning: zinit unavailable (fallback: others/20-omz-fallback.zsh)"
    source "$_zinit_omz_backup"
    unset _zinit_omz_backup
    return 0
  fi
  unset _zinit_omz_backup
  print -u2 "Warning: zinit not available at $ZINIT_HOME"
  return 0
fi

source "$ZINIT_HOME/zinit.zsh"
# zinit's `zi` alias would shadow zoxide's interactive `zi` (50-tools.zsh);
# `zinit` itself stays the way to call zinit.
unalias zi 2>/dev/null

# Optional optimization from Zinit docs: skip some disk checks on startup.
# Safe after the first plugin install; disable with
# ZSH_ZINIT_OPTIMIZE_DISK_ACCESSES=0.
: "${ZSH_ZINIT_OPTIMIZE_DISK_ACCESSES:=1}"
if [[ "${ZSH_ZINIT_OPTIMIZE_DISK_ACCESSES}" == "1" ]]; then
  ZINIT[OPTIMIZE_OUT_DISK_ACCESSES]=1
fi

# Use XDG cache for completion dump to avoid framework-specific cache paths.
# The name carries no $HOST: on a laptop HOST follows the network (DHCP and
# mDNS names), and every new name cost a full compinit plus a stale dump.
# _zsh_compinit_signature already tells dumps apart by what they index.
export ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/.zcompdump"

# -----------------------------------------------------------------------------
# _zinit_compinit_periodic
# @internal
# @description Runs a full compinit when the dump is missing, older than
# ZSH_COMPINIT_CHECK_HOURS (default 24h), or no longer matches fpath (see
# _zsh_compinit_signature); otherwise reuses the dump with -C. Compiles the
# dump to .zwc after a fresh run.
# @noargs
# -----------------------------------------------------------------------------
_zinit_compinit_periodic() {
  setopt localoptions noxtrace noverbose

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local stamp_file="$cache_dir/compinit.last"
  local sig_file="$cache_dir/compinit.sig"
  local current_sig cached_sig="" REPLY
  local -i epoch_last=0 age_hours

  _zsh_compinit_signature
  current_sig="$REPLY"
  [[ -f "$stamp_file" ]] && _zsh_mtime "$stamp_file" && epoch_last=$REPLY
  age_hours=$(( (${EPOCHSECONDS:-0} - epoch_last) / 3600 ))
  [[ -r "$sig_file" ]] && IFS= read -r cached_sig < "$sig_file"

  [[ -d "$cache_dir" && -d "${ZSH_COMPDUMP:h}" ]] ||
    command mkdir -p "$cache_dir" "${ZSH_COMPDUMP:h}" 2>/dev/null
  autoload -Uz compinit

  # Fast path: reuse dump and skip security checks.
  if [[ -f "$ZSH_COMPDUMP" && "$cached_sig" == "$current_sig" ]] &&
      (( age_hours < ${ZSH_COMPINIT_CHECK_HOURS:-24} )); then
    compinit -C -d "$ZSH_COMPDUMP"
    return $?
  fi

  # Full init path.
  local insecure_mode="-i"
  [[ "$ZSH_DISABLE_COMPFIX" == true ]] && insecure_mode="-u"
  compinit "$insecure_mode" -d "$ZSH_COMPDUMP"
  local rc=$?

  if (( rc == 0 )); then
    : >| "$stamp_file" 2>/dev/null
    print -r -- "$current_sig" >| "$sig_file" 2>/dev/null || :
    # Compile the fresh dump so later -C shells load wordcode instead of
    # reparsing ~60KB of text. Zsh ignores a .zwc older than its source, so
    # a failed or skipped compile can never serve stale completions.
    if [[ -f "$ZSH_COMPDUMP" ]] && zcompile "$ZSH_COMPDUMP" 2>/dev/null; then
      command chmod 600 "$ZSH_COMPDUMP.zwc" 2>/dev/null || :
    else
      command rm -f -- "$ZSH_COMPDUMP.zwc" 2>/dev/null
    fi
    # Dumps named after earlier host names (.zcompdump-<HOST>) are orphans.
    local -a stale=("${ZSH_COMPDUMP:h}"/.zcompdump-*(N))
    (( ${#stale} )) && command rm -f -- "${stale[@]}" 2>/dev/null
  fi
  return $rc
}

# -----------------------------------------------------------------------------
# _zinit_replay_compdefs
# @internal
# @description Replays compdefs deferred by plugin snippets loaded around
# compinit (notably Turbo-mode plugins).
# @noargs
# -----------------------------------------------------------------------------
_zinit_replay_compdefs() {
  if typeset -f zicdreplay >/dev/null 2>&1; then
    zicdreplay -q
  elif typeset -f zinit >/dev/null 2>&1; then
    zinit cdreplay -q
  fi
}

# -----------------------------------------------------------------------------
# _zinit_bind_history_substring_keys
# @internal
# @description Binds arrow keys and vi j/k to history-substring-search.
# @noargs
# -----------------------------------------------------------------------------
_zinit_bind_history_substring_keys() {
  bindkey '^[[A' history-substring-search-up
  bindkey '^[[B' history-substring-search-down

  [[ -n "${terminfo[kcuu1]-}" ]] && bindkey "${terminfo[kcuu1]}" history-substring-search-up
  [[ -n "${terminfo[kcud1]-}" ]] && bindkey "${terminfo[kcud1]}" history-substring-search-down

  bindkey -M vicmd 'k' history-substring-search-up
  bindkey -M vicmd 'j' history-substring-search-down

  HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND='bg=green,fg=black,bold'
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND='bg=red,fg=black,bold'
}

# -----------------------------------------------------------------------------
# _zinit_autosuggest_rebind
# @internal
# @description Stands in for zsh-autosuggestions' precmd hook. The plugin
# re-wraps every widget before every prompt so it stays the outermost wrapper;
# with ~1300 widgets that is about 10 ms, a `zle -la` fork included, on every
# prompt. Only a change in the widget table can make it necessary (a plugin,
# the defer queue, or fast-syntax-highlighting adding widgets), so this
# rebinds when the table differs from the one the last rebind left behind.
# The widget count plus every definition is the fingerprint: a new widget
# changes the count, a redefined one its value, and it costs a fraction of
# a millisecond.
# @noargs
# -----------------------------------------------------------------------------
_zinit_autosuggest_rebind() {
  [[ "${#widgets} ${(j: :)widgets}" == "${_ZINIT_AUTOSUGGEST_WIDGETS-}" ]] &&
    return 0
  _zsh_autosuggest_start
  typeset -g _ZINIT_AUTOSUGGEST_WIDGETS="${#widgets} ${(j: :)widgets}"
}

# -----------------------------------------------------------------------------
# _zinit_autosuggest_setup
# @internal
# @description Starts zsh-autosuggestions and swaps its precmd hook for
# _zinit_autosuggest_rebind, in the same slot.
# @noargs
# -----------------------------------------------------------------------------
_zinit_autosuggest_setup() {
  (( $+functions[_zsh_autosuggest_start] )) || return 0
  local -i slot=${precmd_functions[(Ie)_zsh_autosuggest_start]}
  (( slot )) && precmd_functions[slot]=_zinit_autosuggest_rebind
  _zinit_autosuggest_rebind
}

# -----------------------------------------------------------------------------
# _zinit_queue_highlighting
# @internal
# @description Deferred task that queues the fast-syntax-highlighting load
# again. A task queued while the defer queue runs lands in its next batch,
# after every task queued during startup.
# @noargs
# -----------------------------------------------------------------------------
_zinit_queue_highlighting() {
  _zsh_defer _zinit_load_highlighting
}

# -----------------------------------------------------------------------------
# _zinit_load_highlighting
# @internal
# @description Loads fast-syntax-highlighting, then replays the compdefs
# queued while it loaded.
# @noargs
# -----------------------------------------------------------------------------
_zinit_load_highlighting() {
  zinit light zdharma-continuum/fast-syntax-highlighting
  _zinit_replay_compdefs
}

# -----------------------------------------------------------------------------
# _zinit_add_completion_paths
# @internal
# @description Prepends the repository and Docker completion directories to
# fpath, once each, before compinit runs. ZDOTDIR points at $HOME, so the
# repository completions resolve through the config directory instead.
# @noargs
# -----------------------------------------------------------------------------
_zinit_add_completion_paths() {
  _zsh_fpath_prepend \
    "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/completions" \
    "$HOME/.docker/completions"
  return 0
}

# Load OMZ snippets required by selected plugin snippets.
zinit snippet OMZL::completion.zsh

# OMZL::theme-and-appearance derives LS_COLORS from `dircolors -b` in a
# process substitution whenever the variable is empty, which is every new
# terminal (about 9 ms). The cached copy gives it the same value first. The
# output depends on TERM and COLORTERM, so they name the cache; a personal
# ~/.dircolors stays with the snippet.
if [[ -z "${LS_COLORS:-}" && ! -e "$HOME/.dircolors" ]] &&
    (( $+commands[dircolors] )); then
  _zsh_cached_init \
    "dircolors-${${TERM:-none}//[^A-Za-z0-9._-]/_}${COLORTERM:+-color}" \
    "${commands[dircolors]}" -b
fi
zinit snippet OMZL::theme-and-appearance.zsh

# Replaces OMZL::directories.zsh.
setopt auto_cd auto_pushd pushd_ignore_dups pushdminus
alias d='dirs -v | head -10'

# OMZ-compat function replacements are loaded from functions/omz-compatibility.zsh.

# Core OMZ plugin snippets loaded synchronously.
typeset -a _zinit_omz_plugins_sync=(
  git
  sudo
)
typeset -a _zinit_omz_plugins_deferred=(
  jsontools
)

# Homebrew's command-not-found handler performs a synchronous formula lookup
# for every typo and can block the prompt for several seconds. Keep native
# Zsh failure behavior on macOS unless suggestions were explicitly requested.
if [[ "$PLATFORM" != macOS ||
      "${ZSH_ENABLE_BREW_COMMAND_NOT_FOUND:-0}" == 1 ]]; then
  _zinit_omz_plugins_deferred+=(command-not-found)
elif [[ "${functions[command_not_found_handler]-}" ==
    *homebrew_command_not_found_handle* ]]; then
  # A reload must also remove a handler installed earlier in this shell.
  unfunction command_not_found_handler 2>/dev/null
  if [[ "${functions[homebrew_command_not_found_handle]-}" ==
      *'brew which-formula'* ]]; then
    unfunction homebrew_command_not_found_handle 2>/dev/null
  fi
fi
typeset _zinit_omz_plugin
for _zinit_omz_plugin in "${_zinit_omz_plugins_sync[@]}"; do
  zinit snippet "OMZP::${_zinit_omz_plugin}/${_zinit_omz_plugin}.plugin.zsh"
done
for _zinit_omz_plugin in "${_zinit_omz_plugins_deferred[@]}"; do
  zinit ice wait"1" lucid
  zinit snippet "OMZP::${_zinit_omz_plugin}/${_zinit_omz_plugin}.plugin.zsh"
done
unset _zinit_omz_plugin _zinit_omz_plugins_sync _zinit_omz_plugins_deferred

# Additional completion definitions managed by Zinit.
# blockf prevents direct fpath injection from the plugin itself.
if [[ "${ZSH_ENABLE_ZSH_COMPLETIONS}" == "1" ]]; then
  zinit ice lucid blockf atclone"zinit creinstall -q ." atpull"%atclone"
  zinit light zsh-users/zsh-completions
fi

# Run compinit after synchronous snippets, then replay queued compdefs.
_zinit_add_completion_paths
_zinit_compinit_periodic
_zinit_replay_compdefs

# Load fzf-tab after compinit and before autosuggestions/highlighting.
if [[ "${ZSH_ENABLE_FZF_TAB}" == "1" ]]; then
  zinit ice lucid
  zinit light Aloxaf/fzf-tab
fi

# ------------------------- INTERACTIVE CORE PLUGINS ------------------------- #
# Keep core interactive feedback plugins synchronous for immediate availability.
# The OMZ git plugin stays synchronous as well: 60-aliases.zsh redefines
# eleven of its aliases (gl, gcm, gp, ...), which only works while the plugin
# loads first. The same goes for the ls alias of theme-and-appearance.
zinit ice lucid atload"_zinit_autosuggest_setup"
zinit light zsh-users/zsh-autosuggestions

if [[ "$PLATFORM" == "macOS" ]]; then
  zinit ice wait"1" lucid
  zinit light hlissner/zsh-autopair

  zinit ice wait"2" lucid
  zinit light fdellwing/zsh-bat

  if [[ "$ZSH_ENABLE_YOU_SHOULD_USE" == "1" ]]; then
    zinit ice wait"2" lucid
    zinit light MichaelAquilina/zsh-you-should-use
  fi
elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  zinit ice wait"0" lucid
  zinit light chrissicool/zsh-256color
  # No OMZP::fzf: 50-tools.zsh sets up fzf on every platform, and a second
  # `fzf --zsh` would only rebind the same keys a second later.
fi

if [[ "$PLATFORM" == "macOS" ]] || [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Keep this after autosuggestions.
  zinit ice lucid atload"_zinit_bind_history_substring_keys"
  zinit light zsh-users/zsh-history-substring-search

  # Must stay last among interactive plugins. Deferred: widget binding
  # measured ~70-90ms, the largest single startup cost, so highlighting
  # attaches right after the first prompt paints; text typed before that
  # colors on the next keystroke. It wraps every widget that exists when it
  # loads, so it is chained behind the defer queue (00-initialization.zsh),
  # whose integrations (atuin, fzf, ...) define widgets of their own. A Turbo
  # wait"0" slot raced that queue and sometimes won.
  if (( $+functions[_zsh_defer] )); then
    _zsh_defer _zinit_queue_highlighting
  else
    zinit ice wait"0" lucid atload"_zinit_replay_compdefs"
    zinit light zdharma-continuum/fast-syntax-highlighting
  fi
fi

# ============================================================================ #
# End of lib/20-zinit.zsh
