#!/bin/bash
# shellcheck shell=bash
# ============================================================================ #
# +++++++++++++++++++++++ DEVELOPMENT BOOTSTRAP ENTRY ++++++++++++++++++++++++ #
# ============================================================================ #
# Clean-host entry: runs under the system Bash 3.2 before Nix exists, then
# hands over to the packaged executor built from the locked nixpkgs. The
# foundation check activates nothing, installs no runtime and downloads
# nothing.
#
# Usage:
#   scripts/bootstrap/dev-bootstrap.sh [--install-foundation] [plan|apply|verify|prune|report|setup] [options]
#   scripts/bootstrap/dev-bootstrap.sh --check-foundation
#
# ============================================================================ #

set -euo pipefail

bootstrap_error() { printf 'dev-bootstrap: %s\n' "$*" >&2; return 2; }

bootstrap_usage() {
  cat <<'EOF'
Usage: scripts/bootstrap/dev-bootstrap.sh [--install-foundation] [plan|apply|verify|prune|report|setup] [options]
       scripts/bootstrap/dev-bootstrap.sh --check-foundation

No operation defaults to plan. Runtime options pass literally to dev-bootstrap.
--check-foundation checks native platform, Nix daemon, Homebrew/pacman and
build tools (Apple SDK or base-devel).
--install-foundation installs the missing ones (Homebrew and Apple's developer
tools on macOS, base-devel on Arch/CachyOS, and Nix), then continues with the
requested operation. It lists them before administrative authentication.
Existing foundations are never replaced or upgraded by this entry.
Use apply --only LANGUAGE to limit installation; omit apply to avoid runtimes.
--only ... --save-selection keeps that selection for later runs; --all ignores it.
prune lists the installed releases the baseline retired; prune --yes removes them.
report lists the recorded runs; report --last shows the newest one again.
setup walks a person through the same setup: what is here, what apply would do.
EOF
}

bootstrap_platform() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'darwin\n' ;;
    Linux:x86_64)
      if [[ -f /etc/arch-release && -x /usr/bin/pacman ]]; then
        printf 'arch\n'
      else
        bootstrap_error 'Only Arch/CachyOS is supported by the native Linux recipe.'
      fi ;;
    *) bootstrap_error 'Supported targets are Apple Silicon macOS and x86_64 Arch/CachyOS.' ;;
  esac
}

bootstrap_nix() {
  local candidate
  for candidate in "$(command -v nix || true)" /run/current-system/sw/bin/nix \
    /nix/var/nix/profiles/default/bin/nix "$HOME/.nix-profile/bin/nix"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

# A failed or removed installation leaves files the official Nix installer
# refuses to overwrite. Name them before anything changes, instead of
# failing deep in the installer's output.
bootstrap_nix_residue() {
  local path
  for path in /nix /etc/bashrc.backup-before-nix /etc/bash.bashrc.backup-before-nix \
    /etc/zshrc.backup-before-nix /etc/zsh/zshrc.backup-before-nix; do
    if [[ -e "$path" ]]; then printf '%s\n' "$path"; fi
  done
}

bootstrap_native() {
  case "$1" in
    darwin) [[ -x /opt/homebrew/bin/brew ]] ;;
    arch) [[ -x /usr/bin/pacman ]] ;;
  esac
}

# Arch's counterpart of Apple's developer tools: the compiler, make and sudo
# that source builds and this entry assume. -T asks the local database only.
bootstrap_build_tools() {
  /usr/bin/pacman -T base-devel >/dev/null 2>&1
}

bootstrap_sdk() {
  # Project-shell SDK settings must not determine the host foundation.
  local sdk
  sdk=$(unset SDKROOT DEVELOPER_DIR; /usr/bin/xcrun --show-sdk-path 2>/dev/null) || return 1
  [[ -d "$sdk" ]]
}

bootstrap_check() {
  local platform="$1" nix missing=0
  if nix=$(bootstrap_nix); then
    if "$nix" --extra-experimental-features nix-command store info --json --store daemon >/dev/null; then
      printf 'ready   Nix daemon (%s)\n' "$nix"
    else
      printf 'blocked Nix is installed but the daemon cannot be reached\n'
      missing=1
    fi
  else
    printf 'missing Nix\n'; missing=1
  fi
  if bootstrap_native "$platform"; then
    printf 'ready   native package manager\n'
  else
    printf 'missing native package manager\n'; missing=1
  fi
  case "$platform" in
    darwin)
      if bootstrap_sdk; then
        printf 'ready   Apple SDK (presence only; compiler acceptance is separate)\n'
      else
        printf 'missing Apple developer tools or selected SDK\n'; missing=1
      fi ;;
    arch)
      if bootstrap_build_tools; then
        printf 'ready   native build tools (base-devel)\n'
      else
        printf 'missing native build tools (base-devel)\n'; missing=1
      fi ;;
  esac
  return "$missing"
}

bootstrap_download() {
  local url="$1" expected="$2" destination="$3" actual
  curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' "$url" --output "$destination"
  if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$destination")
  else
    actual=$(sha256sum "$destination")
  fi
  [[ "${actual%% *}" == "$expected" ]] || bootstrap_error "Installer checksum mismatch: $url"
}

bootstrap_announce() {
  local platform="$1" missing_native="$2" missing_tools="$3" missing_nix="$4"
  printf 'dev-bootstrap: installing the missing foundations:\n'
  if (( missing_native )); then
    printf '  Homebrew    official installer at a pinned revision, into /opt/homebrew;\n'
    printf '              installs Apple'"'"'s Command Line Tools when they are missing\n'
  fi
  if (( missing_tools )); then
    printf '  base-devel  pacman -S --needed base-devel; no repository refresh or upgrade\n'
  fi
  if (( missing_nix )); then
    printf '  Nix 2.34.8  official multi-user installer: /nix, the nix-daemon service,\n'
    printf '              nixbld build users and Nix lines in the system shell profiles\n'
  fi
  printf 'Administrator authentication follows.\n'
}

bootstrap_install() (
  local platform="$1" missing_nix=0 missing_native=0 missing_tools=0 residue
  bootstrap_nix >/dev/null || missing_nix=1
  bootstrap_native "$platform" || missing_native=1
  if [[ "$platform" == arch ]]; then
    bootstrap_build_tools || missing_tools=1
  fi
  if (( !missing_nix && !missing_native && !missing_tools )); then return; fi
  [[ $(id -u) != 0 ]] || bootstrap_error 'Run as the target user, not root.'
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  if (( missing_nix )); then
    residue=$(bootstrap_nix_residue)
    [[ -z "$residue" ]] || bootstrap_error "Nix is not usable, but an earlier installation left" \
      "${residue//$'\n'/ }. Remove it as https://nix.dev/manual/nix/latest/installation/uninstall describes, then rerun."
  fi
  # Without sudo nothing here can be installed; root has to provide it.
  [[ -x /usr/bin/sudo ]] || bootstrap_error 'sudo is missing; as root, install it and allow this account to use it.'
  bootstrap_announce "$platform" "$missing_native" "$missing_tools" "$missing_nix" >&2
  # Authentication is part of this explicit command; no passwords are stored.
  if [[ -t 0 ]]; then sudo -v; else sudo -n -v; fi
  # Subshell-local, not function-local: EXIT also runs after function unwinding.
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/dev-bootstrap.XXXXXXXX")
  trap 'rm -rf -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  if (( missing_native )); then
    # Homebrew's official installer handles missing CLT through softwareupdate.
    # Pin the acquisition script, not the rolling Homebrew package inventory.
    bootstrap_download \
      https://raw.githubusercontent.com/Homebrew/install/8ab1549dfa1189fd4d818a2116592d8f0ee06d8c/install.sh \
      5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148 \
      "$temporary/homebrew.sh"
    (unset INTERACTIVE; NONINTERACTIVE=1 /bin/bash "$temporary/homebrew.sh" </dev/null)
    bootstrap_native "$platform" || bootstrap_error 'Homebrew installation did not produce /opt/homebrew/bin/brew.'
  fi
  if (( missing_tools )); then
    # The same transaction apply uses: install what is missing, never refresh
    # the sync database alone, never upgrade.
    sudo -n /usr/bin/pacman -S --needed --noconfirm base-devel </dev/null ||
      bootstrap_error 'pacman could not install base-devel; if the sync database is stale, run sudo pacman -Syu first.'
    bootstrap_build_tools || bootstrap_error 'base-devel is still not installed.'
  fi
  if (( missing_nix )); then
    # Match the Nix release the locked nixpkgs carries. On macOS nix-darwin
    # owns later daemon updates; on Linux they stay with the Nix upgrade
    # procedure. The script carries each platform's tarball SHA-256.
    bootstrap_download https://releases.nixos.org/nix/nix-2.34.8/install \
      96c10e102c88809dd9ec0bee89200c4a51eae4c9f6d8698c26b16788d131e078 \
      "$temporary/nix.sh"
    /bin/sh "$temporary/nix.sh" --daemon --yes --no-channel-add </dev/null
    bootstrap_nix >/dev/null || bootstrap_error 'Nix installation did not produce a usable executable.'
  fi
)

bootstrap_main() {
  local root platform nix install=0 check=0
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
  case "${1:-}" in
    --help|-h) bootstrap_usage; return ;;
    --check-foundation) check=1; shift ;;
    --install-foundation) install=1; shift ;;
  esac
  if (( check )); then
    [[ $# == 0 ]] || bootstrap_error '--check-foundation accepts no runtime options.'
  else
    case "${1:-plan}" in
      plan|apply|verify|prune|report|setup) ;;
      *) bootstrap_error 'Expected plan, apply, verify, prune, report or setup; use --help for entry options.' ;;
    esac
  fi
  platform=$(bootstrap_platform)
  if (( install )); then
    bootstrap_install "$platform"
    bootstrap_check "$platform" || return 1
  fi
  if (( check )); then bootstrap_check "$platform"; return; fi
  nix=$(bootstrap_nix) || {
    bootstrap_error 'Nix is missing. Use --check-foundation or --install-foundation.'
    return 2
  }
  # Read-only plan/verify do not require every native prerequisite to exist.
  # Apply retains its own language-specific readiness checks, and asks for
  # administrator rights itself, only when it has packages to install.
  cd -- "$root"
  # How the executor names itself in what to run next: before activation
  # puts dev-bootstrap on PATH, this entry is the command.
  export DEV_BOOTSTRAP_COMMAND="$root/scripts/bootstrap/dev-bootstrap.sh"
  # Apply expression defaults explicitly; the empty attribute selects the
  # resulting derivation and keeps runtime arguments out of Nix selection.
  exec "$nix" --extra-experimental-features 'nix-command flakes' \
    run --impure --expr 'import ./scripts/bootstrap/development-bootstrap.nix {}' '' -- "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then bootstrap_main "$@"; fi

# ============================================================================ #
# End of scripts/bootstrap/dev-bootstrap.sh.
