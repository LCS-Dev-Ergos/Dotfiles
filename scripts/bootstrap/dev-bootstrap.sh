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
#   scripts/bootstrap/dev-bootstrap.sh --update-nix
#
# ============================================================================ #

set -euo pipefail

bootstrap_error() { printf 'dev-bootstrap: %s\n' "$*" >&2; return 2; }

# The installer pins, beside this script.
BOOTSTRAP_PINS="$(dirname -- "${BASH_SOURCE[0]}")/foundation.nix"
# Nix and its CA bundle from the locked nixpkgs, evaluated from the checkout.
BOOTSTRAP_LOCKED_NIX='import ./scripts/bootstrap/development-bootstrap.nix { target = "nix"; }'

bootstrap_usage() {
  cat <<'EOF'
Usage: scripts/bootstrap/dev-bootstrap.sh [--install-foundation] [plan|apply|verify|prune|report|setup] [options]
       scripts/bootstrap/dev-bootstrap.sh --check-foundation
       scripts/bootstrap/dev-bootstrap.sh --update-nix

No operation defaults to plan. Runtime options pass literally to dev-bootstrap.
--check-foundation checks native platform, Nix daemon, Homebrew/pacman and
build tools (Apple SDK or base-devel).
--install-foundation installs the missing ones (Homebrew and Apple's developer
tools on macOS, base-devel on Arch/CachyOS, and Nix), then continues with the
requested operation. It lists them, and asks at a terminal, before
administrative authentication. Existing foundations are never replaced.
--update-nix moves the Linux Nix daemon to the locked nixpkgs' release, never
back; on macOS nix-darwin owns it.
Use apply --only LANGUAGE to limit installation; omit apply to avoid runtimes.
--only ... --save-selection keeps that selection for later runs; --all ignores it.
prune lists the installed releases the baseline retired; prune --yes removes them.
report lists the recorded runs; report --last shows the newest one again.
setup walks a person through the same setup: what is here, what apply would do.
EOF
}

# One pin from foundation.nix: exactly one `name = "value";` line.
bootstrap_pin() {
  local name="$1" line value='' count=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*${name}[[:space:]]=[[:space:]]\"([0-9A-Za-z.]+)\"\;$ ]]; then
      value=${BASH_REMATCH[1]}
      count=$((count + 1))
    fi
  done < "$BOOTSTRAP_PINS"
  [[ $count == 1 ]] || bootstrap_error "$BOOTSTRAP_PINS must declare $name once."
  printf '%s\n' "$value"
}

# Someone at a terminal, who can answer a question and a password prompt.
bootstrap_attended() { [[ -t 0 ]]; }

bootstrap_confirm() {
  local answer=''
  bootstrap_attended || return 0
  printf 'Proceed? [y/N] ' >&2
  read -r answer || true
  case "$answer" in
    y|Y|yes|Yes|YES) return 0 ;;
  esac
  printf 'dev-bootstrap: nothing was changed.\n' >&2
  return 1
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

# The multi-user daemon is a systemd service on Linux.
bootstrap_systemd() { [[ -d /run/systemd/system ]]; }

# The daemon's release, as the daemon itself reports it.
bootstrap_daemon_version() {
  local info
  info=$(NIX_REMOTE=daemon "$1" --extra-experimental-features nix-command store info --json) || return 1
  [[ "$info" =~ \"version\":\"([0-9][0-9A-Za-z.+-]*)\" ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Whether release $1 is older than release $2.
bootstrap_older() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# The official installer links the daemon's unit into the default profile, so
# installing a release there and restarting the service moves the daemon.
bootstrap_official_nix() {
  local unit
  unit=$(readlink /etc/systemd/system/nix-daemon.service 2>/dev/null) || return 1
  [[ "$unit" == /nix/var/nix/profiles/default/* && -x /nix/var/nix/profiles/default/bin/nix-env ]]
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
    # NIX_REMOTE, not --store: an untrusted client's --store is forwarded to
    # the daemon, which ignores it with a warning.
    if NIX_REMOTE=daemon "$nix" --extra-experimental-features nix-command store info --json >/dev/null; then
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
  local version="$1" missing_native="$2" missing_tools="$3" missing_nix="$4"
  printf 'dev-bootstrap: installing the missing foundations:\n'
  if (( missing_native )); then
    printf '  Homebrew    official installer at a pinned revision, into /opt/homebrew;\n'
    printf '              installs Apple'"'"'s Command Line Tools when they are missing\n'
  fi
  if (( missing_tools )); then
    printf '  base-devel  pacman -S --needed base-devel; no repository refresh or upgrade\n'
  fi
  if (( missing_nix )); then
    printf '  Nix %-7s official multi-user installer: /nix, the nix-daemon service,\n' "$version"
    printf '              nixbld build users and Nix lines in the system shell profiles\n'
  fi
  printf 'Administrator authentication follows.\n'
}

# How to clear what a failed or removed Nix installation left behind.
bootstrap_residue_error() {
  bootstrap_error "$1 ${2//$'\n'/ }. Remove it as" \
    'https://nix.dev/manual/nix/latest/installation/uninstall describes, then rerun.'
}

bootstrap_install() (
  local platform="$1" missing_nix=0 missing_native=0 missing_tools=0 residue
  local brew_revision brew_sha256 nix_version nix_sha256
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
    [[ -z "$residue" ]] ||
      bootstrap_residue_error 'Nix is not usable, but an earlier installation left' "$residue"
    if [[ "$platform" == arch ]]; then
      bootstrap_systemd || bootstrap_error 'The Nix multi-user installation needs systemd as the init system.'
    fi
  fi
  # Read before anything changes: assignments stop on a malformed pin file.
  brew_revision=$(bootstrap_pin homebrewRevision)
  brew_sha256=$(bootstrap_pin homebrewSha256)
  nix_version=$(bootstrap_pin nixVersion)
  nix_sha256=$(bootstrap_pin nixSha256)
  # Without sudo nothing here can be installed; root has to provide it.
  [[ -x /usr/bin/sudo ]] || bootstrap_error 'sudo is missing; as root, install it and allow this account to use it.'
  bootstrap_announce "$nix_version" "$missing_native" "$missing_tools" "$missing_nix" >&2
  bootstrap_confirm
  # Authentication is part of this explicit command; no passwords are stored.
  if bootstrap_attended; then sudo -v; else sudo -n -v; fi
  # Subshell-local, not function-local: EXIT also runs after function unwinding.
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/dev-bootstrap.XXXXXXXX")
  trap 'rm -rf -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  if (( missing_native )); then
    # Homebrew's official installer handles missing CLT through softwareupdate.
    # Pin the acquisition script, not the rolling Homebrew package inventory.
    bootstrap_download \
      "https://raw.githubusercontent.com/Homebrew/install/$brew_revision/install.sh" \
      "$brew_sha256" "$temporary/homebrew.sh"
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
    bootstrap_download \
      "https://releases.nixos.org/nix/nix-$nix_version/install" \
      "$nix_sha256" "$temporary/nix.sh"
    # The installer does not roll back; what it leaves blocks the next run.
    if ! /bin/sh "$temporary/nix.sh" --daemon --yes --no-channel-add </dev/null; then
      residue=$(bootstrap_nix_residue)
      [[ -z "$residue" ]] || bootstrap_residue_error 'The Nix installer failed and left' "$residue"
      bootstrap_error 'The Nix installer failed.'
    fi
    bootstrap_nix >/dev/null || bootstrap_error 'Nix installation did not produce a usable executable.'
  fi
)

# Linux has no nix-darwin to move the daemon with the lock: install the
# locked Nix into the profile the daemon's unit links into, then restart it.
bootstrap_update_nix() (
  local platform="$1" root="$2" nix daemon locked paths path nix_out=''
  if [[ "$platform" == darwin ]]; then
    printf 'nix-darwin owns the Nix daemon on macOS; switching the configuration updates it.\n'
    return
  fi
  nix=$(bootstrap_nix) || bootstrap_error 'Nix is missing. Use --install-foundation.'
  bootstrap_official_nix || bootstrap_error 'This Nix is not the official installer'"'"'s:' \
    '/etc/systemd/system/nix-daemon.service does not link into /nix/var/nix/profiles/default.' \
    'Update it with what installed it (pacman -Syu for Arch'"'"'s nix).'
  daemon=$(bootstrap_daemon_version "$nix") || bootstrap_error 'The Nix daemon cannot be reached.'
  cd -- "$root"
  # fetchTree, which reads the lock, is part of the flakes feature.
  locked=$("$nix" --extra-experimental-features 'nix-command flakes' eval --raw --impure \
    --expr "(builtins.head ($BOOTSTRAP_LOCKED_NIX)).version")
  if [[ "$daemon" == "$locked" ]]; then
    printf 'ready   Nix daemon %s, the locked release\n' "$daemon"
    return
  fi
  if ! bootstrap_older "$daemon" "$locked"; then
    printf 'ready   Nix daemon %s, newer than the locked %s; never downgraded\n' "$daemon" "$locked"
    return
  fi
  [[ $(id -u) != 0 ]] || bootstrap_error 'Run as the target user, not root.'
  [[ -x /usr/bin/sudo ]] || bootstrap_error 'sudo is missing; as root, install it and allow this account to use it.'
  # Built, or substituted with signatures checked, before anything changes.
  paths=$("$nix" --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths \
    --impure --expr "$BOOTSTRAP_LOCKED_NIX")
  for path in $paths; do
    [[ "$path" != */*-nix-"$locked" ]] || nix_out=$path
  done
  [[ -n "$nix_out" ]] || bootstrap_error "The locked nixpkgs built no nix-$locked."
  {
    printf 'dev-bootstrap: updating the Nix daemon from %s to %s:\n' "$daemon" "$locked"
    printf '  installs nix and its CA bundle from the locked nixpkgs into\n'
    printf '  /nix/var/nix/profiles/default, then restarts nix-daemon\n'
    printf 'Administrator authentication follows.\n'
  } >&2
  bootstrap_confirm
  if bootstrap_attended; then sudo -v; else sudo -n -v; fi
  # shellcheck disable=SC2086 # one store path per word
  sudo -n -H "$nix_out/bin/nix-env" --profile /nix/var/nix/profiles/default --install $paths
  sudo -n systemctl daemon-reload
  sudo -n systemctl restart nix-daemon.service
  daemon=$(bootstrap_daemon_version "$nix_out/bin/nix") || bootstrap_error 'The restarted Nix daemon cannot be reached.'
  [[ "$daemon" == "$locked" ]] || bootstrap_error "The Nix daemon reports $daemon after the update, not $locked."
  printf 'ready   Nix daemon %s, the locked release\n' "$daemon"
)

bootstrap_main() {
  local root platform nix install=0 check=0 update=0
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
  case "${1:-}" in
    --help|-h) bootstrap_usage; return ;;
    --check-foundation) check=1; shift ;;
    --install-foundation) install=1; shift ;;
    --update-nix) update=1; shift ;;
  esac
  if (( check || update )); then
    [[ $# == 0 ]] || bootstrap_error 'Foundation checks and updates accept no runtime options.'
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
  if (( update )); then bootstrap_update_nix "$platform" "$root"; return; fi
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
