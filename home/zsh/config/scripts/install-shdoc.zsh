#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ SHDOC INSTALLER ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Installs a checksum-pinned shdoc v1.4 release with a portable gawk wrapper.
#
# Usage: install-shdoc.zsh [--prefix PATH] [--check]
#   --prefix PATH  Install below PATH; default: SHDOC_PREFIX or ~/.local.
#   --check        Verify the existing installation without changing files.
# ============================================================================ #

emulate -L zsh
setopt localoptions no_aliases pipefail

typeset -r shdoc_helpers="${${(%):-%N}:A:h}/_shared-helpers.zsh"
if [[ -r "$shdoc_helpers" ]]; then
  source "$shdoc_helpers"
else
  print -u2 "[ERROR] Shared helpers not found: $shdoc_helpers"
  exit 1
fi

typeset -r shdoc_version="1.4"
typeset -r shdoc_sha256=\
"856bdc62db15e4970c59f011e9a779d6a23e86f4f123707e25f5390d14c9b191"
typeset -r shdoc_url=\
"https://raw.githubusercontent.com/reconquest/shdoc/v${shdoc_version}/shdoc"
typeset shdoc_prefix="${SHDOC_PREFIX:-$HOME/.local}"
typeset -gi shdoc_check_only=0

while (( $# )); do
  case "$1" in
    --prefix)
      (( $# >= 2 )) || {
        _zsh_ui_log error "install-shdoc: --prefix requires a path"
        exit 2
      }
      shdoc_prefix="${2:A}"
      shift
      ;;
    --check)
      shdoc_check_only=1
      ;;
    -h|--help)
      print -rl -- \
        "Usage: install-shdoc.zsh [--prefix PATH] [--check]" \
        "" \
        "  --prefix PATH  Install below PATH; default: SHDOC_PREFIX/~/.local." \
        "  --check        Verify the installation without changing files." \
        "  -h, --help     Show this help."
      exit 0
      ;;
    *)
      _zsh_ui_log error "install-shdoc: unknown option: $1"
      exit 2
      ;;
  esac
  shift
done

typeset shdoc_data_dir="$shdoc_prefix/share/shdoc"
typeset shdoc_bin_dir="$shdoc_prefix/bin"
typeset shdoc_program="$shdoc_data_dir/shdoc.awk"
typeset shdoc_wrapper="$shdoc_bin_dir/shdoc"

_shdoc_checksum() {
  local file="$1" output
  if (( $+commands[sha256sum] )); then
    output="$(command sha256sum -- "$file")" || return 1
  elif (( $+commands[shasum] )); then
    output="$(command shasum -a 256 -- "$file")" || return 1
  else
    _zsh_ui_log error "install-shdoc: sha256sum or shasum is required"
    return 1
  fi
  REPLY="${output%%[[:space:]]*}"
}

_shdoc_verify() {
  local file="$1"
  [[ -r "$file" ]] || {
    _zsh_ui_log error "install-shdoc: pinned source not found: $file"
    return 1
  }
  _shdoc_checksum "$file" || return 1
  [[ "$REPLY" == "$shdoc_sha256" ]] || {
    _zsh_ui_log error "install-shdoc: checksum mismatch: $REPLY"
    return 1
  }
}

if (( shdoc_check_only )); then
  _shdoc_verify "$shdoc_program" || exit 1
  [[ -x "$shdoc_wrapper" ]] || {
    _zsh_ui_log error "install-shdoc: wrapper not executable: $shdoc_wrapper"
    exit 1
  }
  "$shdoc_wrapper" --version | command grep -Fq "v${shdoc_version}" || {
    _zsh_ui_log error \
      "install-shdoc: command did not report v${shdoc_version}"
    exit 1
  }
  _zsh_ui_log ok "shdoc v${shdoc_version} is installed and verified."
  exit 0
fi

(( $+commands[curl] )) || {
  _zsh_ui_log error "install-shdoc: curl is required"
  exit 1
}
(( $+commands[gawk] )) || {
  _zsh_ui_log error "install-shdoc: gawk is required"
  exit 1
}

typeset shdoc_tmp_base="${TMPDIR:-/tmp}"
[[ -d "$shdoc_tmp_base" && -w "$shdoc_tmp_base" ]] || shdoc_tmp_base="/tmp"
typeset shdoc_tmp_root=""
shdoc_tmp_root="$(mktemp -d "$shdoc_tmp_base/install-shdoc.XXXXXX")" || {
  _zsh_ui_log error "install-shdoc: could not create a temporary directory"
  exit 1
}
trap 'command rm -rf -- "$shdoc_tmp_root"' EXIT INT TERM

typeset shdoc_download="$shdoc_tmp_root/shdoc.awk"
_zsh_ui_spinner "Downloading shdoc v${shdoc_version}." \
  curl --fail --silent --show-error --location \
  "$shdoc_url" --output "$shdoc_download" || exit 1
_shdoc_verify "$shdoc_download" || exit 1

command mkdir -p -- "$shdoc_data_dir" "$shdoc_bin_dir" || exit 1
typeset shdoc_program_tmp=""
typeset shdoc_wrapper_tmp=""
shdoc_program_tmp="$(mktemp "$shdoc_data_dir/.shdoc.awk.XXXXXX")" || exit 1
shdoc_wrapper_tmp="$(mktemp "$shdoc_bin_dir/.shdoc.XXXXXX")" || {
  command rm -f -- "$shdoc_program_tmp"
  exit 1
}

command cp -- "$shdoc_download" "$shdoc_program_tmp" || exit 1
{
  print -r -- '#!/bin/sh'
  printf 'exec gawk -E %s "$@"\n' "${(q)shdoc_program}"
} >| "$shdoc_wrapper_tmp" || exit 1
command chmod 644 "$shdoc_program_tmp" || exit 1
command chmod 755 "$shdoc_wrapper_tmp" || exit 1
command mv -f -- "$shdoc_program_tmp" "$shdoc_program" || exit 1
command mv -f -- "$shdoc_wrapper_tmp" "$shdoc_wrapper" || exit 1

_zsh_ui_card \
  "shdoc v${shdoc_version} installed" \
  "Wrapper: $shdoc_wrapper" \
  "Add to PATH: $shdoc_bin_dir"

# ============================================================================ #
# End of install-shdoc.zsh
