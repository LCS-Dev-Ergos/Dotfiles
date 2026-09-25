#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ DEVELOPMENT ENVIRONMENT DOCTOR ++++++++++++++++++++++ #
# ============================================================================ #
# Health check for the language runtime managers configured by lib/80-languages
# and lib/90-path.zsh: Nix, Homebrew, rustup, ghcup, opam, SDKMAN, pyenv, rbenv,
# fnm, conda, Coursier, elan, juliaup, Alire, fpcupdeluxe, and the brew-provided
# language binaries.
#
# Scope:
#   C/C++ driver startup is checked here, including CC/CXX overrides, and on
#   macOS whether the Nix toolchain check (`cc-toolchain-check`, which covers
#   compile, link and runtime compatibility) still holds for the SDK in use.
#   Use `get_toolchain_info` for detailed vendors/wrappers.
#
# Two tiers:
#   Local (default)  Presence, active version, runtime startup, PATH shadowing.
#                    No network access, no manager initialization.
#   Remote (-u)      Batched update checks for managers that expose a native,
#                    machine-readable check. Cached, timed out, and opt-in.
#
# Registry:
#   packages/runtime-managers.tsv, one tab-separated row per manager:
#     id label platform root_var root_default probe version_cmd language_bin
#     managed_list formula update_hint activation runtime_cmd
#   runtime_cmd is optional for older registries: "-" skips it, "version"
#   reuses the active-version probe, otherwise it is a local startup command.
#   Only audited, non-interactive commands belong here; no install or update.
#   activation is "always" when the manager keeps its shims on PATH for every
#   shell, or "session" when it has to be activated per shell (fnm, conda).
#   "-" means "not applicable". "hook" routes the field to an override function
#   named _devdoctor_<field>_<id>. Commands are split on whitespace into argv,
#   so they may not contain quoted arguments.
#
# Environment:
#   DEVDOCTOR_REGISTRY     Registry path override.
#   DEVDOCTOR_JOBS         Concurrent probe jobs; defaults to the CPU count.
#   DEVDOCTOR_TIMEOUT      Seconds per local probe (default 5).
#   DEVDOCTOR_NET_TIMEOUT  Seconds per remote check (default 30).
#   DEVDOCTOR_UPDATE_TTL   Update-cache lifetime in seconds (default 21600).
#
# Author: LCS-Dev-Ergos
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

_devdoctor_helpers_dir="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts"
if [[ -r "${_devdoctor_helpers_dir}/_shared-helpers.zsh" ]]; then
  # shellcheck disable=SC1091
  source "${_devdoctor_helpers_dir}/_shared-helpers.zsh"
else
  printf "[ERROR] Shared helpers not found: %s/_shared-helpers.zsh\n" \
    "$_devdoctor_helpers_dir" >&2
  return 1 2>/dev/null || exit 1
fi
unset _devdoctor_helpers_dir

typeset -g _DEVDOCTOR_SCRIPT_DIR="${${(%):-%N}:A:h}"
typeset -g _DEVDOCTOR_ZSH_ROOT="${_DEVDOCTOR_SCRIPT_DIR:h:h}"

# +++++++++++++++++++++++++++++ GENERIC HELPERS ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_expand
# @internal
# @description Expands a leading tilde in a registry path into $HOME and
# stores the result in REPLY; "-" yields an empty REPLY.
# @arg $1 string Registry path value.
# -----------------------------------------------------------------------------
_devdoctor_expand() {
  emulate -L zsh
  local value="$1"
  if [[ -z "$value" || "$value" == "-" ]]; then
    REPLY=""
    return 0
  fi
  REPLY="${value/#\~/$HOME}"
}

# -----------------------------------------------------------------------------
# _devdoctor_run_timeout
# @internal
# @description Runs a command with a wall-clock limit, preferring coreutils
# timeout and falling back to a zsh watchdog when it is unavailable.
# @arg $1 integer Timeout in seconds.
# @arg $@ command Command and arguments to execute.
# @exitcode 2 If no command is given.
# @stdout The command's standard output.
# -----------------------------------------------------------------------------
_devdoctor_run_timeout() {
  emulate -L zsh
  setopt localoptions no_aliases no_monitor no_notify
  local -i secs="${1:-5}"
  shift
  (( $# )) || return 2
  (( secs > 0 )) || secs=1

  local runner=""
  if (( $+commands[timeout] )); then
    runner="timeout"
  elif (( $+commands[gtimeout] )); then
    runner="gtimeout"
  fi
  if [[ -n "$runner" ]]; then
    command "$runner" -k 1 "$secs" "$@" 2>/dev/null
    return $?
  fi

  # Fallback: poll the child rather than run a watchdog. A watchdog subshell
  # leaves its `sleep` orphaned when signalled, and $$/$RANDOM are inherited
  # unchanged by forked subshells, so parallel probes would share a temp file.
  local out_file
  out_file="$(command mktemp "${TMPDIR:-/tmp}/devdoctor-timeout.XXXXXX")" || return 1
  local -i job_pid job_status=124 ticks=0 limit=$(( secs * 10 ))
  zmodload -i zsh/zselect 2>/dev/null

  { "$@" >| "$out_file" 2>/dev/null } &
  job_pid=$!

  while (( ticks < limit )); do
    kill -0 "$job_pid" 2>/dev/null || break
    if (( $+builtins[zselect] )); then
      zselect -t 10 2>/dev/null
    else
      command sleep 0.1
    fi
    (( ticks++ ))
  done

  if kill -0 "$job_pid" 2>/dev/null; then
    kill -TERM "$job_pid" 2>/dev/null
    # A probe can ignore TERM. Do not turn a five-second health check into an
    # unbounded wait when coreutils timeout is unavailable.
    local -i grace=0
    while (( grace < 10 )) && kill -0 "$job_pid" 2>/dev/null; do
      if (( $+builtins[zselect] )); then
        zselect -t 10 2>/dev/null
      else
        command sleep 0.1
      fi
      (( grace++ ))
    done
    kill -KILL "$job_pid" 2>/dev/null
    wait "$job_pid" 2>/dev/null
    job_status=124
  else
    wait "$job_pid" 2>/dev/null
    job_status=$?
  fi

  command cat -- "$out_file" 2>/dev/null
  command rm -f -- "$out_file" 2>/dev/null
  return $job_status
}

# -----------------------------------------------------------------------------
# _devdoctor_first_line
# @internal
# @description Stores the first non-empty, whitespace-trimmed line of the
# given text in REPLY.
# @arg $1 string Text to reduce.
# -----------------------------------------------------------------------------
_devdoctor_first_line() {
  emulate -L zsh
  setopt localoptions extendedglob
  local line
  REPLY=""
  for line in ${(f)1}; do
    line="${line##[[:space:]]#}"
    line="${line%%[[:space:]]#}"
    [[ -n "$line" ]] || continue
    REPLY="$line"
    return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# _devdoctor_version_token
# @internal
# @description Reduces a version banner to its first version-like token,
# keeping the whole first line when no numeric token is present. The result
# is stored in REPLY.
# @arg $1 string Raw version output.
# -----------------------------------------------------------------------------
_devdoctor_version_token() {
  emulate -L zsh
  setopt localoptions extendedglob
  _devdoctor_first_line "$1" || { REPLY=""; return 1; }

  local word candidate
  for word in ${=REPLY}; do
    # Strip a leading marker such as "v" or "go" before testing the token, so
    # `go version go1.27.1 darwin/arm64` reduces to 1.27.1 like everything else.
    candidate="${word##[^0-9]##}"
    candidate="${candidate%%[,;)]##}"
    if [[ "$candidate" == [0-9]##(.[0-9]##)#* ]]; then
      REPLY="$candidate"
      return 0
    fi
  done
  return 0
}

# -----------------------------------------------------------------------------
# _devdoctor_clean_field
# @internal
# @description Collapses tabs and newlines in a record field into spaces, so a
# probe's output cannot shift the columns of the tab-separated record format.
# The result is stored in REPLY.
# @arg $1 string Field value.
# -----------------------------------------------------------------------------
_devdoctor_clean_field() {
  emulate -L zsh
  local value="${1//$'\t'/ }"
  REPLY="${value//$'\n'/ }"
}

# -----------------------------------------------------------------------------
# _devdoctor_origin
# @internal
# @description Classifies where a resolved binary comes from, storing nix,
# brew, manager, system, or other in REPLY.
# @arg $1 path Binary path as found in PATH.
# @arg $@ path Manager roots that would claim the binary.
# -----------------------------------------------------------------------------
_devdoctor_origin() {
  emulate -L zsh
  local raw="$1"
  shift
  local resolved="${raw:A}"
  local root

  for root in "$@"; do
    [[ -n "$root" ]] || continue
    if [[ "$raw" == "$root"/* || "$resolved" == "$root"/* ]]; then
      REPLY="manager"
      return 0
    fi
  done

  local brew_prefix="${HOMEBREW_PREFIX:-/opt/homebrew}"
  case "$resolved" in
    /nix/store/*|/run/current-system/sw/*|/etc/profiles/per-user/*)
      REPLY="nix" ;;
    "$brew_prefix"/*|/opt/homebrew/*|/usr/local/Cellar/*|/home/linuxbrew/*)
      REPLY="brew" ;;
    /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*|/Library/*|/System/*)
      REPLY="system" ;;
    *)
      REPLY="other" ;;
  esac
}

# +++++++++++++++++++++++++++++ REGISTRY LOADING +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_registry_is_trusted
# @internal
# @description Checks that the registry is a regular, non-symlink file owned by
# this user or by root and writable by nobody else. Its fields are executed as
# commands, so a registry another account can rewrite is a command-injection
# vector; DEVDOCTOR_REGISTRY makes the path caller-supplied.
# @arg $1 path Registry file to check.
# @exitcode 1 If the file is missing, a symlink, foreign-owned, or shared-writable.
# -----------------------------------------------------------------------------
_devdoctor_registry_is_trusted() {
  emulate -L zsh
  local file="$1"
  [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 1

  local -A stat_info
  local -i uid mode
  if (( ${_ZSH_HAS_ZSTAT:-0} )) && zstat -L -H stat_info -- "$file" 2>/dev/null; then
    uid=$stat_info[uid]
    mode=$stat_info[mode]
  else
    local raw_uid raw_mode
    if [[ "$OSTYPE" == darwin* ]]; then
      raw_uid="$(command stat -f %u "$file" 2>/dev/null)" || return 1
      raw_mode="$(command stat -f %Lp "$file" 2>/dev/null)" || return 1
    else
      raw_uid="$(command stat -c %u "$file" 2>/dev/null)" || return 1
      raw_mode="$(command stat -c %a "$file" 2>/dev/null)" || return 1
    fi
    [[ "$raw_uid" == [0-9]## && "$raw_mode" == [0-7]## ]] || return 1
    uid=$raw_uid
    mode=$(( 8#$raw_mode ))
  fi

  # Root-owned is expected: the deployed registry lives in the Nix store.
  (( uid == EUID || uid == 0 )) || return 1
  (( mode & 8#22 )) && return 1
  return 0
}

# -----------------------------------------------------------------------------
# _devdoctor_registry_path
# @internal
# @description Stores the effective registry path in REPLY.
# @noargs
# -----------------------------------------------------------------------------
_devdoctor_registry_path() {
  REPLY="${DEVDOCTOR_REGISTRY:-$_DEVDOCTOR_ZSH_ROOT/packages/runtime-managers.tsv}"
}

# -----------------------------------------------------------------------------
# _devdoctor_load_registry
# @internal
# @description Parses the registry into _devdoctor_ids and the _devdoctor_row
# map, skipping rows that do not apply to the current platform.
# @noargs
# @exitcode 1 If the registry is unreadable or contains no usable rows.
# @set _devdoctor_ids array Manager ids in registry order.
# @set _devdoctor_row association Manager id to raw registry row.
# -----------------------------------------------------------------------------
_devdoctor_load_registry() {
  emulate -L zsh
  setopt localoptions no_aliases

  setopt localoptions extendedglob
  _devdoctor_registry_path
  local registry="$REPLY"
  [[ -r "$registry" ]] || {
    _zsh_ui_log error "Manager registry not found: $registry"
    return 1
  }
  _devdoctor_registry_is_trusted "$registry" || {
    _zsh_ui_log error "Refusing an untrusted manager registry: $registry"
    return 1
  }

  _shared_detect_platform
  typeset -ga _devdoctor_ids=()
  typeset -gA _devdoctor_row=()

  local line
  local -a fields
  local -i errors=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    fields=("${(@ps:\t:)line}")
    if (( ${#fields[@]} != 12 && ${#fields[@]} != 13 )); then
      _zsh_ui_log error "Malformed registry row: ${fields[1]:-$line}"
      (( errors++ ))
      continue
    fi
    # The id becomes a filename in the work directory, so keep it to a shape
    # that cannot escape it.
    if [[ "$fields[1]" != [A-Za-z0-9_-]## ]]; then
      _zsh_ui_log error "Invalid manager id: $fields[1]"
      (( errors++ ))
      continue
    fi
    if [[ -n "${_devdoctor_row[$fields[1]]-}" ]]; then
      _zsh_ui_log error "Duplicate manager id: $fields[1]"
      (( errors++ ))
      continue
    fi
    case "$fields[3]" in
      any) ;;
      "${SHARED_PLATFORM:-unknown}") ;;
      macOS|Linux) continue ;;
      *)
        _zsh_ui_log error "Invalid platform '$fields[3]' for '$fields[1]'."
        (( errors++ ))
        continue
        ;;
    esac
    _devdoctor_ids+=("$fields[1]")
    _devdoctor_row[$fields[1]]="$line"
  done < "$registry"

  (( errors == 0 && ${#_devdoctor_ids} > 0 ))
}

# -----------------------------------------------------------------------------
# _devdoctor_unpack_row
# @internal
# @description Splits a registry row into the per-manager field variables used
# by the probes.
# @arg $1 string Raw tab-separated registry row.
# @set dd_id string Manager id.
# @set dd_label string Display label.
# @set dd_root_var string Environment variable naming the manager root.
# @set dd_root_default string Fallback manager root.
# @set dd_probe string Presence probe specification.
# @set dd_version string Active-version command.
# @set dd_lang_bin string Language binary the manager should own.
# @set dd_managed string Managed-version listing command.
# @set dd_formula string Homebrew formula name.
# @set dd_hint string Suggested update command.
# @set dd_activation string "always" or "session".
# @set dd_runtime string Runtime startup command, "version", or "-".
# -----------------------------------------------------------------------------
_devdoctor_unpack_row() {
  emulate -L zsh
  local -a fields=("${(@ps:\t:)1}")
  dd_id="$fields[1]"
  dd_label="$fields[2]"
  dd_root_var="$fields[4]"
  dd_root_default="$fields[5]"
  dd_probe="$fields[6]"
  dd_version="$fields[7]"
  dd_lang_bin="$fields[8]"
  dd_managed="$fields[9]"
  dd_formula="$fields[10]"
  dd_hint="$fields[11]"
  dd_activation="$fields[12]"
  dd_runtime="${fields[13]:--}"
}

# ++++++++++++++++++++++++++++ MANAGER OVERRIDES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_version_erlang
# @internal
# @description Starts the Erlang VM and prints its OTP release without a shell.
# @stdout OTP release.
# -----------------------------------------------------------------------------
_devdoctor_version_erlang() {
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" erl -noshell \
    -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
}

# -----------------------------------------------------------------------------
# _devdoctor_version_perl
# @internal
# @description Starts Perl and prints its version without parsing a banner.
# @stdout Perl version.
# -----------------------------------------------------------------------------
_devdoctor_version_perl() {
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" perl -e 'print "$^V\n"'
}

# -----------------------------------------------------------------------------
# _devdoctor_compiler_command
# @internal
# @description Resolves CC/CXX as an argv array, including quoted paths and
# launcher arguments, without evaluating shell substitutions.
# @arg $1 string cc or cxx.
# @set reply array Compiler command and arguments.
# -----------------------------------------------------------------------------
_devdoctor_compiler_command() {
  emulate -L zsh
  local spec
  if [[ "$1" == cc ]]; then
    spec="${CC:-cc}"
  else
    spec="${CXX:-c++}"
  fi
  # An exact executable path may contain spaces without shell quoting.
  if [[ -x "$spec" && ! -d "$spec" ]]; then
    reply=("$spec")
  else
    reply=(${(z)spec})
    reply=("${(@Q)reply}")
  fi
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_cc
# @internal
# @description Detects the selected C compiler, retaining invalid explicit CC
# values so the startup probe can report them as broken.
# @set REPLY string Empty root; a compiler has no manager-owned directory.
# -----------------------------------------------------------------------------
_devdoctor_probe_cc() {
  REPLY=""
  [[ -n "${CC:-}" ]] || (( $+commands[cc] ))
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_cxx
# @internal
# @description Detects the selected C++ compiler, including explicit CXX.
# @set REPLY string Empty root.
# -----------------------------------------------------------------------------
_devdoctor_probe_cxx() {
  REPLY=""
  [[ -n "${CXX:-}" ]] || (( $+commands[c++] ))
}

# -----------------------------------------------------------------------------
# _devdoctor_version_cc
# @internal
# @description Starts the selected C compiler with --version.
# @stdout Compiler version banner.
# -----------------------------------------------------------------------------
_devdoctor_version_cc() {
  local -a reply
  _devdoctor_compiler_command cc
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" "${reply[@]}" --version
}

# -----------------------------------------------------------------------------
# _devdoctor_version_cxx
# @internal
# @description Starts the selected C++ compiler with --version.
# @stdout Compiler version banner.
# -----------------------------------------------------------------------------
_devdoctor_version_cxx() {
  local -a reply
  _devdoctor_compiler_command cxx
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" "${reply[@]}" --version
}

# -----------------------------------------------------------------------------
# _devdoctor_version_flutter
# @internal
# @description Reads Flutter's cached version and starts its bundled Dart VM.
# Avoids the flutter launcher, which can download artifacts even for --version.
# @stdout Cached Flutter version.
# -----------------------------------------------------------------------------
_devdoctor_version_flutter() {
  emulate -L zsh
  local launcher="${commands[flutter]:-}"
  [[ -n "$launcher" ]] || return 127
  local sdk="${launcher:A:h:h}"
  local metadata="$sdk/bin/cache/flutter.version.json"
  [[ -r "$metadata" ]] || return 65
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
    "$sdk/bin/cache/dart-sdk/bin/dart" --version >/dev/null || return $?
  command sed -n 's/.*"flutterVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata"
}

# -----------------------------------------------------------------------------
# _devdoctor_verdict_cctoolchain
# @internal
# @description Asks the Nix C/C++ toolchain check whether it has verified the
# drivers against the SDK, linker and macOS in use now. An Xcode, Command Line
# Tools or macOS update changes those without rebuilding anything, so the
# verification the last system build performed can go stale unnoticed; this
# row is where that shows.
# @set REPLY string The check's one-line verdict.
# @exitcode 0 If verified, 1 if not verified for this host, 2 if the check
# could not run.
# -----------------------------------------------------------------------------
_devdoctor_verdict_cctoolchain() {
  emulate -L zsh
  local output
  local -i status_code=0
  output="$(_devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
    cc-toolchain-check --status 2>&1)" || status_code=$?
  _devdoctor_first_line "$output"
  case $status_code in
    0) return 0 ;;
    1) return 1 ;;
    124|137)
      REPLY="status probe timed out"
      return 1
      ;;
    *)
      [[ -n "$REPLY" ]] || REPLY="status probe failed (exit $status_code)"
      return 2
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_sdkman
# @internal
# @description Detects SDKMAN without sourcing its init script.
# @noargs
# @exitcode 1 If SDKMAN is not installed.
# @set REPLY string The SDKMAN root.
# -----------------------------------------------------------------------------
_devdoctor_probe_sdkman() {
  emulate -L zsh
  local root="${SDKMAN_DIR:-$HOME/.sdkman}"
  [[ -r "$root/bin/sdkman-init.sh" ]] || return 1
  REPLY="$root"
}

# -----------------------------------------------------------------------------
# _devdoctor_version_sdkman
# @internal
# @description Reads the current Java candidate from its symlink.
# @arg $1 path SDKMAN root.
# @exitcode 1 If no current Java candidate is selected.
# @stdout The selected candidate version.
# -----------------------------------------------------------------------------
_devdoctor_version_sdkman() {
  emulate -L zsh
  local current="$1/candidates/java/current"
  [[ -e "$current" ]] || return 1
  print -r -- "${current:A:t}"
}

# -----------------------------------------------------------------------------
# _devdoctor_managed_sdkman
# @internal
# @description Lists the SDKMAN candidates that have a current selection.
# @arg $1 path SDKMAN root.
# @stdout One candidate name per line.
# -----------------------------------------------------------------------------
_devdoctor_managed_sdkman() {
  emulate -L zsh
  setopt localoptions null_glob
  local current
  for current in "$1"/candidates/*/current; do
    print -r -- "${current:h:t}"
  done
}

# -----------------------------------------------------------------------------
# _devdoctor_version_fnm
# @internal
# @description Reports the Node version fnm would serve. `fnm current` fails
# outright until `fnm env` has been applied, so a shell that has not activated
# fnm is answered from the default alias that lib/80-languages.zsh maintains.
# @arg $1 path The fnm root.
# @exitcode 1 If neither the active version nor a default alias is available.
# @stdout The version string.
# -----------------------------------------------------------------------------
_devdoctor_version_fnm() {
  emulate -L zsh
  setopt localoptions no_aliases

  if _devdoctor_activated_fnm; then
    _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" fnm current && return 0
  fi

  # The alias points at <root>/node-versions/<version>/installation, so the
  # version is the parent of the resolved leaf, not the leaf itself.
  local alias_link="${1:-${FNM_DIR:-$HOME/.local/share/fnm}}/aliases/default"
  [[ -e "$alias_link" ]] || return 1
  local resolved="${alias_link:A}"
  if [[ "${resolved:t}" == "installation" ]]; then
    print -r -- "${resolved:h:t}"
  else
    print -r -- "${resolved:t}"
  fi
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_conda
# @internal
# @description Detects conda at the two roots lib/80-languages.zsh knows about,
# without triggering its lazy initialization.
# @noargs
# @exitcode 1 If conda is not installed.
# @set REPLY string The conda installation root.
# -----------------------------------------------------------------------------
_devdoctor_probe_conda() {
  emulate -L zsh
  local candidate
  for candidate in "$HOME/.miniforge3/bin/conda" "/opt/miniconda3/bin/conda"; do
    if [[ -x "$candidate" ]]; then
      REPLY="${candidate:h:h}"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# _devdoctor_version_conda
# @internal
# @description Reports the conda version from its own binary.
# @arg $1 path Conda root.
# @stdout The conda version banner.
# -----------------------------------------------------------------------------
_devdoctor_version_conda() {
  emulate -L zsh
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" "$1/bin/conda" --version
}

# -----------------------------------------------------------------------------
# _devdoctor_managed_conda
# @internal
# @description Lists conda environments without initializing the shell hook.
# @arg $1 path Conda root.
# @stdout One environment path per line.
# -----------------------------------------------------------------------------
_devdoctor_managed_conda() {
  emulate -L zsh
  local out
  out="$(_devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
    "$1/bin/conda" env list)" || return 1
  local line
  for line in ${(f)out}; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    print -r -- "$line"
  done
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_coursier
# @internal
# @description Detects Coursier and resolves its platform-specific root.
# @noargs
# @exitcode 1 If the Coursier launcher is not installed.
# @set REPLY string The Coursier data root.
# -----------------------------------------------------------------------------
_devdoctor_probe_coursier() {
  emulate -L zsh
  (( $+commands[cs] || $+commands[coursier] )) || return 1
  _shared_detect_platform
  if [[ "${SHARED_PLATFORM:-}" == "macOS" ]]; then
    REPLY="$HOME/Library/Application Support/Coursier"
  else
    REPLY="$HOME/.local/share/coursier"
  fi
}

# -----------------------------------------------------------------------------
# _devdoctor_version_coursier
# @internal
# @description Reports the Coursier launcher version.
# @arg $1 path Coursier root.
# @stdout The version banner.
# -----------------------------------------------------------------------------
_devdoctor_version_coursier() {
  emulate -L zsh
  local launcher="cs"
  (( $+commands[cs] )) || launcher="coursier"
  _devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" "$launcher" version
}

# -----------------------------------------------------------------------------
# _devdoctor_activated_fnm
# @internal
# @description Reports whether fnm has been activated in this shell. Its lazy
# initializer only runs on the first fnm invocation, so a fresh shell serves
# Node from the Nix fallback by design (home/dev/languages/javascript).
# @noargs
# @exitcode 1 If no fnm multishell is active.
# -----------------------------------------------------------------------------
_devdoctor_activated_fnm() {
  emulate -L zsh
  [[ -n "${FNM_MULTISHELL_PATH:-}" && -d "${FNM_MULTISHELL_PATH}/bin" ]]
}

# -----------------------------------------------------------------------------
# _devdoctor_activated_conda
# @internal
# @description Reports whether a conda environment is active in this shell.
# @noargs
# @exitcode 1 If no environment is active.
# -----------------------------------------------------------------------------
_devdoctor_activated_conda() {
  emulate -L zsh
  [[ -n "${CONDA_PREFIX:-}" || -n "${CONDA_DEFAULT_ENV:-}" ]]
}

# -----------------------------------------------------------------------------
# _devdoctor_is_activated
# @internal
# @description Reports whether a per-shell manager is currently activated. A
# manager with no hook is treated as dormant, which is the verdict that does
# not raise an alarm.
# @arg $1 string Manager id.
# @exitcode 1 If the manager is not activated in this shell.
# -----------------------------------------------------------------------------
_devdoctor_is_activated() {
  emulate -L zsh
  local id="$1"
  (( $+functions[_devdoctor_activated_$id] )) || return 1
  "_devdoctor_activated_$id"
}

# +++++++++++++++++++++++++++++++ PROBE ENGINE +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_resolve_root
# @internal
# @description Resolves every root a manager owns. The registry default may be
# a comma-separated list; the environment variable, when set, replaces only the
# first entry. The primary root lands in REPLY and the full list in reply.
# @arg $1 string Environment variable name, or "-".
# @arg $2 string Default root or comma-separated root list, or "-".
# @set REPLY string The primary manager root.
# @set reply array Every root the manager owns.
# -----------------------------------------------------------------------------
_devdoctor_resolve_root() {
  emulate -L zsh
  local var_name="$1"
  local fallback="$2"
  local -a raw_roots=("${(@s:,:)fallback}")
  local part

  reply=()
  for part in "${raw_roots[@]}"; do
    _devdoctor_expand "$part"
    [[ -n "$REPLY" ]] && reply+=("$REPLY")
  done

  if [[ -n "$var_name" && "$var_name" != "-" && -n "${(P)var_name-}" ]]; then
    reply[1]="${(P)var_name}"
  fi

  REPLY="${reply[1]:-}"
}

# -----------------------------------------------------------------------------
# _devdoctor_probe_present
# @internal
# @description Evaluates a registry presence probe: a command name, a
# file:/dir: path, or "hook" for a per-manager override.
# @arg $1 string Manager id.
# @arg $2 string Probe specification.
# @arg $3 string Root resolved from the registry.
# @exitcode 1 If the manager is not installed.
# @set REPLY string The manager root, refined by a hook when one applies.
# -----------------------------------------------------------------------------
_devdoctor_probe_present() {
  emulate -L zsh
  local id="$1" probe="$2" root="$3"

  case "$probe" in
    hook)
      if (( $+functions[_devdoctor_probe_$id] )); then
        REPLY=""
        "_devdoctor_probe_$id" || return 1
        [[ -n "$REPLY" ]] || REPLY="$root"
        return 0
      fi
      return 1
      ;;
    file:*)
      _devdoctor_expand "${probe#file:}"
      [[ -r "$REPLY" ]] || return 1
      REPLY="$root"
      ;;
    dir:*)
      _devdoctor_expand "${probe#dir:}"
      [[ -d "$REPLY" ]] || return 1
      REPLY="$root"
      ;;
    -|"")
      return 1
      ;;
    *)
      (( $+commands[$probe] )) || return 1
      REPLY="$root"
      ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# _devdoctor_active_version
# @internal
# @description Runs a manager's version command, or its hook, and stores the
# reduced version token in REPLY.
# @arg $1 string Manager id.
# @arg $2 string Version command, "hook", or "-".
# @arg $3 path Manager root.
# @exitcode 1 If the version cannot be determined.
# -----------------------------------------------------------------------------
_devdoctor_active_version() {
  emulate -L zsh
  local id="$1" spec="$2" root="$3"
  local raw=""

  case "$spec" in
    -|"")
      REPLY=""
      return 1
      ;;
    hook)
      (( $+functions[_devdoctor_version_$id] )) || { REPLY=""; return 1; }
      raw="$("_devdoctor_version_$id" "$root" 2>/dev/null)" || { local rc=$?; REPLY=""; return $rc; }
      ;;
    *)
      local -a argv_parts=(${=spec})
      (( ${#argv_parts} )) || { REPLY=""; return 1; }
      (( $+commands[$argv_parts[1]] )) || [[ -x "$argv_parts[1]" ]] || { REPLY=""; return 127; }
      raw="$(_devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
        "${argv_parts[@]}" 2>/dev/null)" || { local rc=$?; REPLY=""; return $rc; }
      ;;
  esac

  _devdoctor_version_token "$raw"
  [[ -n "$REPLY" ]] || return 65
}

# -----------------------------------------------------------------------------
# _devdoctor_managed_count
# @internal
# @description Counts the versions a manager currently manages and stores the
# count in REPLY; an empty REPLY means the manager does not manage versions.
# @arg $1 string Manager id.
# @arg $2 string Listing command, "hook", or "-".
# @arg $3 path Manager root.
# @exitcode 1 If the listing failed or does not apply.
# -----------------------------------------------------------------------------
_devdoctor_managed_count() {
  emulate -L zsh
  local id="$1" spec="$2" root="$3"
  local raw=""
  REPLY=""

  case "$spec" in
    -|"")
      return 1
      ;;
    hook)
      (( $+functions[_devdoctor_managed_$id] )) || return 1
      raw="$("_devdoctor_managed_$id" "$root" 2>/dev/null)" || return 1
      ;;
    *)
      local -a argv_parts=(${=spec})
      (( ${#argv_parts} )) || return 1
      (( $+commands[$argv_parts[1]] )) || return 1
      raw="$(_devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
        "${argv_parts[@]}" 2>/dev/null)" || return 1
      ;;
  esac

  # Managers mark the active entry with a leading "*" (fnm) or indent it; both
  # still count as an installed version.
  setopt localoptions extendedglob
  local -i count=0
  local line
  for line in ${(f)raw}; do
    line="${line##[[:space:]]#}"
    line="${line##\*[[:space:]]#}"
    [[ -n "$line" ]] || continue
    (( count++ ))
  done
  REPLY="$count"
  return 0
}

# -----------------------------------------------------------------------------
# _devdoctor_check_one
# @internal
# @description Probes a single manager and prints one tab-separated record:
# id, state, active version, origin, and a short detail.
# @arg $1 string Manager id.
# @stdout The manager's record.
# -----------------------------------------------------------------------------
_devdoctor_check_one() {
  emulate -L zsh
  setopt localoptions no_aliases extendedglob

  local dd_id dd_label dd_root_var dd_root_default dd_probe dd_version
  local dd_lang_bin dd_managed dd_formula dd_hint dd_activation dd_runtime
  _devdoctor_unpack_row "${_devdoctor_row[$1]}"

  if [[ "$dd_id" == cc || "$dd_id" == cxx ]]; then
    local -a reply
    _devdoctor_compiler_command "$dd_id"
    dd_lang_bin="${reply[1]:--}"
  fi

  local state="ok" active="-" origin="-" detail=""

  _devdoctor_resolve_root "$dd_root_var" "$dd_root_default"
  local root="$REPLY"
  local -a roots=("${reply[@]}")

  if ! _devdoctor_probe_present "$dd_id" "$dd_probe" "$root"; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$dd_label" "absent" "-" "-" ""
    return 0
  fi
  root="$REPLY"
  if [[ -n "$root" ]]; then
    if (( ${#roots} )); then
      roots[1]="$root"
    else
      roots=("$root")
    fi
  fi

  # A declared root that has vanished is the clearest breakage signal there is.
  if [[ -n "$root" && ! -d "$root" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$dd_label" "broken" "-" "-" \
      "root missing: ${root/#$HOME/~}"
    return 0
  fi

  if (( $+functions[_devdoctor_broken_$dd_id] )); then
    REPLY=""
    if "_devdoctor_broken_$dd_id"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$dd_label" "broken" "-" "-" "$REPLY"
      return 0
    fi
  fi

  local -i managed=-1
  if _devdoctor_managed_count "$dd_id" "$dd_managed" "$root"; then
    managed="$REPLY"
  fi

  local -i dormant=0
  if [[ "$dd_activation" == "session" ]] &&
     ! _devdoctor_is_activated "$dd_id"; then
    dormant=1
  fi

  local -i version_status=0
  if [[ "$dd_runtime" == version ]] && (( dormant || managed == 0 )); then
    # Version commands for rustup/elan-like shims can install a runtime when
    # none is selected. An empty/dormant manager is not permission to do that.
    active="-"
  elif _devdoctor_active_version "$dd_id" "$dd_version" "$root"; then
    active="$REPLY"
  else
    version_status=$?
  fi

  if (( version_status && ! dormant && managed != 0 )) && [[ "$dd_version" != "-" ]]; then
    state="unknown"
    detail="version probe failed or timed out"
  fi

  # Startup is separate from manager presence/version. Reuse a version probe
  # when it already starts the runtime; avoid invoking it twice. A dormant or
  # empty manager must not initialize/download a runtime just for diagnosis.
  if [[ "$dd_runtime" != "-" ]] && (( ! dormant && managed != 0 )); then
    local -i runtime_status=0
    if [[ "$dd_runtime" == "version" ]]; then
      runtime_status=$version_status
    else
      if _devdoctor_active_version "$dd_id" "$dd_runtime" "$root"; then
        active="$REPLY"
      else
        runtime_status=$?
      fi
    fi
    case "$runtime_status" in
      0) [[ -n "$detail" ]] || detail="runtime starts" ;;
      124|137)
        state="unknown"
        active="-"
        detail="runtime probe timed out"
        ;;
      65)
        state="unknown"
        active="-"
        detail="runtime probe returned no version"
        ;;
      *)
        state="broken"
        active="-"
        detail="runtime probe failed (exit $runtime_status): $dd_lang_bin"
        ;;
    esac
  fi

  # Where does the language binary actually come from? This is the question the
  # PATH ordering in lib/90-path.zsh exists to answer, so it is worth asking.
  local language_path="${commands[$dd_lang_bin]:-}"
  if [[ "$dd_lang_bin" == */* && -x "$dd_lang_bin" ]]; then
    language_path="$dd_lang_bin"
  fi
  if [[ "$dd_lang_bin" != "-" && -n "$language_path" ]]; then
    _devdoctor_origin "$language_path" "${roots[@]}"
    origin="$REPLY"
    if [[ "$origin" != "manager" && "$state" == "ok" ]]; then
      if (( managed > 0 )); then
        # A per-shell manager that nobody activated has not lost a race; it was
        # never in one. Calling that "shadowed" is a false alarm.
        if (( dormant )); then
          state="dormant"
          detail="not activated here; $dd_lang_bin comes from $origin"
        else
          state="shadowed"
          detail="$dd_lang_bin resolves to $origin: ${language_path/#$HOME/~}"
        fi
      elif (( managed == 0 )); then
        state="unused"
        detail="no managed versions; $dd_lang_bin comes from $origin"
      fi
    fi
  elif (( managed == 0 )) && [[ "$state" == "ok" ]]; then
    state="unused"
    detail="no managed versions installed"
  fi

  if [[ -z "$detail" && managed -ge 0 ]]; then
    detail="$managed managed"
  fi
  if (( dormant )) && [[ "$state" == ok ]]; then
    state="dormant"
    detail="not activated here; runtime probe skipped"
  fi
  if [[ "$state" == ok && ( "$dd_id" == cc || "$dd_id" == cxx ) ]]; then
    detail="${language_path/#$HOME/~}"
    [[ "$language_path" == /nix/store/* ]] && detail+=" (store-pinned)"
  elif [[ "$state" == ok && "$dd_id" == flutter ]]; then
    detail="cached Flutter version; bundled Dart starts"
  fi

  # A row whose health is a verdict of its own, rather than a startup probe,
  # reports it through _devdoctor_verdict_<id>: 0 keeps the row ok, 1 makes it
  # unknown and anything else broken, with REPLY as the detail.
  if [[ "$state" == ok ]] && (( $+functions[_devdoctor_verdict_$dd_id] )); then
    local -i verdict=0
    REPLY=""
    "_devdoctor_verdict_$dd_id" || verdict=$?
    case $verdict in
      0) ;;
      1) state="unknown" ;;
      *) state="broken" ;;
    esac
    [[ -n "$REPLY" ]] && detail="$REPLY"
  fi

  _devdoctor_clean_field "${active:--}"
  active="$REPLY"
  _devdoctor_clean_field "$detail"
  detail="$REPLY"
  printf '%s\t%s\t%s\t%s\t%s\n' "$dd_label" "$state" "${active:--}" \
    "$origin" "$detail"
}

# +++++++++++++++++++++++++++++++ REMOTE TIER ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_update_signals
# @internal
# @description Collects update signals from the managers that expose a native,
# machine-readable check, batching Homebrew into a single query and caching the
# result. Managers without such a check are deliberately absent from the output.
# @arg $1 boolean Non-zero to bypass the cache.
# @stdout One "brew:<formula>" or "manager:<id>" token per line.
# -----------------------------------------------------------------------------
_devdoctor_update_signals() {
  emulate -L zsh
  setopt localoptions no_aliases
  local -i refresh="${1:-0}"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/devdoctor-updates.cache"
  local -i ttl="${DEVDOCTOR_UPDATE_TTL:-21600}"
  local -i net_timeout="${DEVDOCTOR_NET_TIMEOUT:-30}"

  if (( ! refresh )) && _zsh_cache_is_fresh "$cache" "$ttl"; then
    command cat -- "$cache" 2>/dev/null
    return 0
  fi

  local -a signals=()
  local raw line

  if (( $+commands[brew] )); then
    if raw="$(_devdoctor_run_timeout $(( net_timeout * 2 )) \
        brew outdated --quiet 2>/dev/null)"; then
      for line in ${(f)raw}; do
        [[ -n "$line" ]] && signals+=("brew:${line##*/}")
      done
    fi
  fi

  if (( $+commands[rustup] )); then
    if raw="$(_devdoctor_run_timeout "$net_timeout" rustup check 2>/dev/null)"; then
      [[ "$raw" == *"Update available"* ]] && signals+=("manager:rustup")
    fi
  fi

  if (( ${#signals} )); then
    print -rl -- "${signals[@]}" | _zsh_cache_put "$cache"
    print -rl -- "${signals[@]}"
  else
    : | _zsh_cache_put "$cache"
  fi
}

# ++++++++++++++++++++++++++++++ PATH CONFLICTS ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_path_conflicts
# @internal
# @description Prints one tab-separated record per PATH problem: a missing
# directory, competing non-system binaries, or a version-manager
# shim directory that has lost its priority over Homebrew and Nix.
# @arg $1 string Comma-separated binaries already verified at their manager
# root, or "-". Package-manager alternatives to these are expected fallbacks.
# @arg $@ string Language binaries to test for shadowing.
# @stdout Kind, subject, and detail per line.
# -----------------------------------------------------------------------------
_devdoctor_path_conflicts() {
  emulate -L zsh
  setopt localoptions no_aliases extendedglob

  local -a entries=("${(@s/:/)PATH}")
  local -a managed_winners=("${(@s:,:)1}")
  shift
  local entry bin
  local -i index=0 first_shim=0 first_package=0

  for entry in "${entries[@]}"; do
    (( index++ ))
    [[ -z "$entry" ]] && continue
    if [[ ! -d "$entry" ]]; then
      printf '%s\t%s\t%s\n' "stale entry" "${entry/#$HOME/~}" \
        "directory does not exist"
      continue
    fi
    if [[ "$entry" == */shims ]]; then
      (( first_shim == 0 )) && first_shim=$index
      local -a shim_files=("$entry"/*(N))
      if (( ${#shim_files} == 0 )); then
        printf '%s\t%s\t%s\n' "empty shims" "${entry/#$HOME/~}" \
          "on PATH but the manager installed no shims"
      fi
    fi
    if (( first_package == 0 )); then
      case "$entry" in
        /nix/store/*|/etc/profiles/per-user/*|/run/current-system/sw/*)
          first_package=$index ;;
        "${HOMEBREW_PREFIX:-/opt/homebrew}"/bin|/opt/homebrew/bin|/usr/local/bin)
          first_package=$index ;;
      esac
    fi
  done

  # lib/90-path.zsh puts dynamic shims at the top on purpose; losing that order
  # is how rbenv and pyenv silently stop being the thing that answers.
  if (( first_shim > 0 && first_package > 0 && first_shim > first_package )); then
    printf '%s\t%s\t%s\n' "shim priority" "${entries[$first_shim]/#$HOME/~}" \
      "resolved after ${entries[$first_package]/#$HOME/~}"
  fi

  local -a matches resolved
  local match seen winner_origin
  for bin in "$@"; do
    [[ "$bin" == "-" || -z "$bin" ]] && continue
    (( ${managed_winners[(Ie)$bin]} )) && continue
    matches=(${(f)"$(whence -pa "$bin" 2>/dev/null)"})
    (( ${#matches} > 1 )) || continue
    _devdoctor_origin "$matches[1]"
    winner_origin="$REPLY"
    resolved=()
    for match in "${matches[@]}"; do
      # Apple's /usr/bin drivers and Perl remain installed alongside a
      # chosen development toolchain. They are fallbacks, not a PATH fault.
      if [[ "$winner_origin" != system ]]; then
        _devdoctor_origin "$match"
        [[ "$REPLY" == system ]] && continue
      fi
      seen="${match:A}"
      (( ${resolved[(Ie)$seen]} )) || resolved+=("$seen")
    done
    (( ${#resolved} > 1 )) || continue
    printf '%s\t%s\t%s\n' "shadowed binary" "$bin" \
      "${#resolved} origins, winner ${matches[1]/#$HOME/~}"
  done
}

# -----------------------------------------------------------------------------
# _devdoctor_npm_prefix_conflict
# @internal
# @description Reports a global npm prefix that sits inside a version manager's
# tree. npm installs global CLIs into the active Node version by default, so
# selecting another default or deleting that version takes every globally
# installed tool with it. 75-variables.zsh pins NPM_CONFIG_PREFIX outside the
# tree precisely to avoid that.
# @arg $@ path Manager roots that own versioned installations.
# @stdout One conflict record when the prefix is version-scoped.
# -----------------------------------------------------------------------------
_devdoctor_npm_prefix_conflict() {
  emulate -L zsh
  setopt localoptions no_aliases

  (( $+commands[npm] )) || return 0

  local prefix="${NPM_CONFIG_PREFIX:-}"
  if [[ -z "$prefix" ]]; then
    # Only the already-broken case pays for this Node start-up.
    prefix="$(_devdoctor_run_timeout "${DEVDOCTOR_TIMEOUT:-5}" \
      npm config get prefix 2>/dev/null)" || return 0
  fi
  _devdoctor_first_line "$prefix" || return 0
  prefix="$REPLY"
  [[ -n "$prefix" && "$prefix" != "undefined" && "$prefix" != "null" ]] || return 0

  local root
  for root in "$@"; do
    [[ -n "$root" ]] || continue
    if [[ "$prefix" == "$root"/* ]]; then
      printf '%s\t%s\t%s\n' "npm globals" "${prefix/#$HOME/~}" \
        "inside a managed version tree; they vanish with that version"
      return 0
    fi
  done
  return 0
}

# +++++++++++++++++++++++++++++++ PRESENTATION +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _devdoctor_json_escape
# @internal
# @description Escapes a value for inclusion in a JSON string, storing the
# result in REPLY.
# @arg $1 string Value to escape.
# -----------------------------------------------------------------------------
_devdoctor_json_escape() {
  emulate -L zsh
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  REPLY="$value"
}

# -----------------------------------------------------------------------------
# _devdoctor_state_rank
# @internal
# @description Maps a state to its exit-code contribution, stored in REPLY.
# @arg $1 string State name.
# -----------------------------------------------------------------------------
_devdoctor_state_rank() {
  case "$1" in
    broken) REPLY=2 ;;
    shadowed|unknown) REPLY=1 ;;
    *) REPLY=0 ;;
  esac
}

# -----------------------------------------------------------------------------
# _devdoctor_fanout
# @internal
# @description Probes every requested manager concurrently, writing one record
# per manager into the work directory. Concurrency is capped so a machine with
# many managers cannot spawn an unbounded number of processes.
# @arg $1 path Work directory that receives one file per manager id.
# @arg $@ string Manager ids to probe.
# -----------------------------------------------------------------------------
_devdoctor_fanout() {
  emulate -L zsh
  setopt localoptions no_aliases no_monitor no_notify
  local work="$1"
  shift

  # The probes are dominated by process startup and file lookups, not by CPU,
  # so the CPU count is the wrong cap: measured on 19 managers, four jobs cost
  # 1.00s and sixteen cost 0.66s. The registry bounds the fan-out already, so
  # the default is simply the manager count, held under a hard ceiling.
  local -i max_jobs="${DEVDOCTOR_JOBS:-$#}"
  (( max_jobs > 0 )) || max_jobs=1
  (( max_jobs > 16 )) && max_jobs=16
  local -i running=0
  local id
  for id in "$@"; do
    { _devdoctor_check_one "$id" >| "$work/$id" 2>/dev/null } &
    if (( ++running >= max_jobs )); then
      wait
      running=0
    fi
  done
  wait
}

# -----------------------------------------------------------------------------
# _devdoctor_with_progress
# @internal
# @description Runs work under the shared function spinner when the loaded
# helpers provide one. Sourcing this script against an older deployed
# _shared-helpers.zsh would otherwise fail the call outright and silently
# discard the work's output.
# @arg $1 string Progress label.
# @arg $@ command Function or command, and its arguments, to execute.
# @stdout Whatever the command wrote to standard output.
# -----------------------------------------------------------------------------
_devdoctor_with_progress() {
  emulate -L zsh
  local label="$1"
  shift
  (( $# )) || return 2

  if (( $+functions[_zsh_ui_spinner_fn] )); then
    _zsh_ui_spinner_fn "$label" "$@"
    return $?
  fi

  _zsh_ui_log info "$label" >&2
  "$@"
}

# ++++++++++++++++++++++++++++++ MAIN FUNCTION +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# devdoctor
# @description Reports the health of every language runtime manager on this
# machine: presence, active version, managed versions, where the language
# binary actually resolves from, startup failures and PATH problems. Detailed
# C/C++ compile/link checks remain in the Nix toolchain check.
# @option -u | --updates Also query managers that expose a native update check.
# @option --refresh Bypass the cached update signals.
# @option --only Restrict the report to a comma-separated list of manager ids.
# @option --all Include managers that are not installed.
# @option --json Emit raw records instead of a rendered report.
# @option -h | --help Show usage information.
# @exitcode 1 If a probe is inconclusive, a manager is shadowed, or PATH holds a stale
# entry, an empty shim directory, or shims that lost their priority.
# @exitcode 2 If a manager is broken, or the registry cannot be read.
# -----------------------------------------------------------------------------
devdoctor() {
  emulate -L zsh
  setopt localoptions no_aliases no_monitor no_notify pipefail

  local -i want_updates=0 want_refresh=0 want_all=0 want_json=0
  local only_spec=""
  local id

  while (( $# )); do
    case "$1" in
      -u|--updates) want_updates=1 ;;
      --refresh) want_refresh=1; want_updates=1 ;;
      --all) want_all=1 ;;
      --json) want_json=1 ;;
      --only)
        shift
        [[ -n "${1-}" ]] || { print -u2 "devdoctor: --only needs a value"; return 2; }
        only_spec="$1"
        ;;
      --only=*) only_spec="${1#--only=}" ;;
      -h|--help)
        print -rl -- \
          "Usage: devdoctor [options]" \
          "" \
          "  -u, --updates  Query managers with a native update check." \
          "      --refresh  Bypass the cached update signals." \
          "      --only ID  Restrict to a comma-separated list of manager ids." \
          "      --all      Include managers that are not installed." \
          "      --json     Emit raw records instead of a rendered report." \
          "  -h, --help     Show this help." \
          "" \
          "States: ok, outdated, dormant (a per-shell manager not activated" \
          "here), unused, shadowed, broken, absent, unknown." \
          "" \
          "Runtime startup is checked where declared; OK is not a full build test." \
          "CC/CXX overrides are honoured. Detailed C/C++ info: get_toolchain_info."
        return 0
        ;;
      *)
        print -u2 "devdoctor: unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _devdoctor_load_registry || return 2

  local -a wanted=("${_devdoctor_ids[@]}")
  if [[ -n "$only_spec" ]]; then
    local -a requested=("${(@s:,:)only_spec}")
    wanted=()
    for id in "${requested[@]}"; do
      [[ -z "$id" ]] && continue
      if [[ -z "${_devdoctor_row[$id]-}" ]]; then
        print -u2 "devdoctor: unknown manager id: $id"
        return 2
      fi
      wanted+=("$id")
    done
    (( ${#wanted} )) || return 2
  fi

  local work
  work="$(command mktemp -d "${TMPDIR:-/tmp}/devdoctor.XXXXXX")" || return 2
  command chmod 700 "$work" 2>/dev/null

  {
    # Local probes are bounded, so they get a spinner only where one can
    # actually be drawn; elsewhere its label would be pure noise. The remote
    # tier below is worth announcing in every mode.
    local plural_wanted="s"
    (( ${#wanted} == 1 )) && plural_wanted=""
    _zsh_ui_resolve_mode
    if [[ "$REPLY" == gum && -t 2 ]]; then
      _devdoctor_with_progress "Probing ${#wanted} manager${plural_wanted}" \
        _devdoctor_fanout "$work" "${wanted[@]}"
    else
      _devdoctor_fanout "$work" "${wanted[@]}"
    fi

    # Update signals are collected after the local tier so the fast answers are
    # never held hostage by the network.
    local -A outdated_formula=()
    local -A outdated_manager=()
    if (( want_updates )); then
      local signal
      for signal in ${(f)"$(_devdoctor_with_progress "Querying update sources" \
          _devdoctor_update_signals $want_refresh)"}; do
        case "$signal" in
          brew:*) outdated_formula[${signal#brew:}]=1 ;;
          manager:*) outdated_manager[${signal#manager:}]=1 ;;
        esac
      done
    fi

    local -a rows=()
    local -a json_rows=()
    local -i worst=0
    local record label state active origin detail
    local dd_id dd_label dd_root_var dd_root_default dd_probe dd_version
    local dd_lang_bin dd_managed dd_formula dd_hint dd_activation dd_runtime
    local -a lang_bins=()
    local -a managed_winner_bins=()
    local -a manager_roots=()

    for id in "${wanted[@]}"; do
      [[ -r "$work/$id" ]] || continue
      record="$(<"$work/$id")"
      [[ -n "$record" ]] || continue
      local -a fields=("${(@ps:\t:)record}")
      label="$fields[1]" state="$fields[2]" active="$fields[3]"
      origin="$fields[4]" detail="${fields[5]:-}"

      _devdoctor_unpack_row "${_devdoctor_row[$id]}"
      [[ "$dd_lang_bin" != "-" ]] && lang_bins+=("$dd_lang_bin")
      if [[ "$origin" == manager ]]; then
        managed_winner_bins+=("$dd_lang_bin")
      fi
      _devdoctor_resolve_root "$dd_root_var" "$dd_root_default"
      manager_roots+=("${reply[@]}")

      if [[ "$state" == "ok" ]] && (( want_updates )); then
        if [[ -n "${outdated_manager[$id]-}" ]] ||
           { [[ "$dd_formula" != "-" ]] &&
             [[ -n "${outdated_formula[$dd_formula]-}" ]] }; then
          state="outdated"
          detail="${dd_hint:#-}"
        fi
      fi

      if [[ "$state" == "absent" ]] && (( ! want_all )); then
        continue
      fi

      _devdoctor_state_rank "$state"
      (( REPLY > worst )) && worst=$REPLY

      rows+=("${id}"$'\t'"${label}"$'\t'"${(U)state}"$'\t'"${active}"$'\t'"${origin}"$'\t'"${detail}")

      if (( want_json )); then
        local json_line="{"
        _devdoctor_json_escape "$id";     json_line+="\"id\":\"$REPLY\","
        _devdoctor_json_escape "$label";  json_line+="\"label\":\"$REPLY\","
        _devdoctor_json_escape "$state";  json_line+="\"state\":\"$REPLY\","
        _devdoctor_json_escape "$active"; json_line+="\"active\":\"$REPLY\","
        _devdoctor_json_escape "$origin"; json_line+="\"origin\":\"$REPLY\","
        _devdoctor_json_escape "$detail"; json_line+="\"detail\":\"$REPLY\"}"
        json_rows+=("$json_line")
      fi
    done

    local -a conflicts=()
    conflicts=(${(f)"$(_devdoctor_path_conflicts "${(j:,:)managed_winner_bins}" "${(@u)lang_bins}")"})
    conflicts+=(${(f)"$(_devdoctor_npm_prefix_conflict "${(@u)manager_roots}")"})

    # Several origins for one binary is the normal state of this machine, so it
    # is reported but never fails the run; a stale entry, an empty shim
    # directory or a lost shim priority is something to act on.
    local conflict
    for conflict in "${conflicts[@]}"; do
      [[ "${conflict%%$'\t'*}" == "shadowed binary" ]] && continue
      (( worst < 1 )) && worst=1
      break
    done

    if (( want_json )); then
      print -r -- "{"
      print -r -- "  \"managers\": ["
      local -i i=0
      for record in "${json_rows[@]}"; do
        (( ++i ))
        print -r -- "    $record$( (( i < ${#json_rows} )) && print -n , )"
      done
      print -r -- "  ],"
      print -r -- "  \"conflicts\": ["
      i=0
      for record in "${conflicts[@]}"; do
        (( ++i ))
        local -a cf=("${(@ps:\t:)record}")
        local cj="{"
        _devdoctor_json_escape "$cf[1]"; cj+="\"kind\":\"$REPLY\","
        _devdoctor_json_escape "$cf[2]"; cj+="\"subject\":\"$REPLY\","
        _devdoctor_json_escape "${cf[3]:-}"; cj+="\"detail\":\"$REPLY\"}"
        print -r -- "    $cj$( (( i < ${#conflicts} )) && print -n , )"
      done
      print -r -- "  ]"
      print -r -- "}"
      return $worst
    fi

    _shared_detect_platform
    local plural_rows="s"
    (( ${#rows} == 1 )) && plural_rows=""
    _shared_banner "Development Environment" \
      "$(_shared_platform_pretty) · ${#rows} manager${plural_rows}"

    if (( ${#rows} )); then
      _zsh_ui_table --status 3 \
        $'ID\tMANAGER\tSTATE\tACTIVE\tORIGIN\tDETAIL' "${rows[@]}"
    else
      _zsh_ui_log warn "No managers matched the selection."
    fi

    if (( ${#conflicts} )); then
      print -r -- ""
      _shared_section "PATH conflicts · ${#conflicts}"
      _zsh_ui_table --status 1 $'KIND\tSUBJECT\tDETAIL' "${conflicts[@]}"
    fi

    # One line that answers "is anything wrong?" without reading the table.
    local -A state_counts=()
    local -a tally=()
    local counted
    for record in "${rows[@]}"; do
      counted="${${(@ps:\t:)record}[3]}"
      (( state_counts[$counted]++ ))
    done
    for counted in OK OUTDATED DORMANT UNUSED SHADOWED UNKNOWN BROKEN ABSENT; do
      (( ${state_counts[$counted]:-0} )) &&
        tally+=("${state_counts[$counted]} ${(L)counted}")
    done
    print -r -- ""
    if (( ${#tally} )); then
      case "$worst" in
        0) _zsh_ui_log ok "${(j:, :)tally}." ;;
        1) _zsh_ui_log warn "${(j:, :)tally}; review the flagged entries." ;;
        *) _zsh_ui_log error "${(j:, :)tally}; review the flagged entries." ;;
      esac
    fi

    if (( ! want_updates )); then
      _zsh_ui_log info "Run 'devdoctor --updates' for native update checks."
    fi

    return $worst
  } always {
    command rm -rf -- "$work" 2>/dev/null
  }
}

# ============================================================================ #
# End of dev-doctor.zsh
