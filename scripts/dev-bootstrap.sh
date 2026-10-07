#!/bin/bash
# Clean-host entry: Bash 3.2 before Nix, the packaged executor afterwards.
# No activation, runtime installation or downloads occur during foundation check.
set -euo pipefail

bootstrap_error() { printf 'dev-bootstrap: %s\n' "$*" >&2; return 2; }

bootstrap_usage() {
  cat <<'EOF'
Usage: scripts/dev-bootstrap.sh [--install-foundation] [plan|apply|verify] [options]
       scripts/dev-bootstrap.sh --check-foundation

No operation defaults to plan. Runtime options pass literally to dev-bootstrap.
--check-foundation checks native platform, Nix daemon, Homebrew/pacman and SDK.
--install-foundation installs missing Nix/Homebrew on Apple Silicon macOS,
then continues with the requested operation. Administrative authentication may
be required. Existing foundations are never replaced or upgraded by this entry.
Use apply --only LANGUAGE to limit installation; omit apply to avoid runtimes.
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
  for candidate in "$(command -v nix || true)" \
    /nix/var/nix/profiles/default/bin/nix "$HOME/.nix-profile/bin/nix"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

bootstrap_native() {
  case "$1" in
    darwin) [[ -x /opt/homebrew/bin/brew ]] ;;
    arch) [[ -x /usr/bin/pacman ]] ;;
  esac
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
  if [[ "$platform" == darwin ]]; then
    if bootstrap_sdk; then
      printf 'ready   Apple SDK (presence only; compiler acceptance is separate)\n'
    else
      printf 'missing Apple developer tools or selected SDK\n'; missing=1
    fi
  fi
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

bootstrap_install() (
  local platform="$1" nix missing_nix=0 missing_native=0
  [[ "$platform" == darwin ]] || bootstrap_error 'Automatic foundation installation is currently macOS-only.'
  nix=$(bootstrap_nix) || missing_nix=1
  bootstrap_native "$platform" || missing_native=1
  if (( !missing_nix && !missing_native )); then return; fi
  [[ $(id -u) != 0 ]] || bootstrap_error 'Run as the target user, not root.'
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
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
  if (( missing_nix )); then
    # Match the initial Nix release in the locked Darwin configuration.
    # Subsequent daemon/package updates remain nix-darwin-owned.
    bootstrap_download https://releases.nixos.org/nix/nix-2.34.8/install \
      96c10e102c88809dd9ec0bee89200c4a51eae4c9f6d8698c26b16788d131e078 \
      "$temporary/nix.sh"
    /bin/sh "$temporary/nix.sh" --daemon --yes --no-channel-add </dev/null
    bootstrap_nix >/dev/null || bootstrap_error 'Nix installation did not produce a usable executable.'
  fi
)

bootstrap_interactive() { [[ -t 0 ]]; }

bootstrap_authenticate() {
  # Arch apply installs missing native packages through sudo -n, which never
  # prompts. Ask once here while a terminal is attached; without one, the
  # executor stops before any change and names the command to run instead.
  local platform="$1" argument
  shift
  [[ "$platform" == arch && "${1:-plan}" == apply ]] || return 0
  for argument in "$@"; do
    [[ "$argument" != --runtimes-only ]] || return 0
  done
  bootstrap_interactive || return 0
  sudo -v || bootstrap_error 'Administrator authentication failed; apply needs it to install missing native packages.'
}

bootstrap_main() {
  local root platform nix install=0 check=0
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
  case "${1:-}" in
    --help|-h) bootstrap_usage; return ;;
    --check-foundation) check=1; shift ;;
    --install-foundation) install=1; shift ;;
  esac
  if (( check )); then
    [[ $# == 0 ]] || bootstrap_error '--check-foundation accepts no runtime options.'
  else
    case "${1:-plan}" in
      plan|apply|verify) ;;
      *) bootstrap_error 'Expected plan, apply or verify; use --help for entry options.' ;;
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
  # Apply retains its own language-specific readiness checks.
  bootstrap_authenticate "$platform" "$@" || return
  cd -- "$root"
  # Apply expression defaults explicitly; the empty attribute selects the
  # resulting derivation and keeps runtime arguments out of Nix selection.
  exec "$nix" --extra-experimental-features 'nix-command flakes' \
    run --impure --expr 'import ./scripts/development-bootstrap.nix {}' '' -- "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then bootstrap_main "$@"; fi
