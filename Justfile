# Maintenance commands for this repository; `just` lists them by group.
# Recipes run from the repository root and pass extra arguments through.
# just comes from the Nix configuration: on a machine without Nix yet, run
# scripts/bootstrap/dev-bootstrap.sh directly.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

darwin := "LCSMacBook-Pro"
linux := "lcs-dev@LCS.Dev-Legion-Cachy"
ci_shell := 'import ./scripts/bootstrap/development-bootstrap.nix { target = "ci"; }'

[private]
default:
    @just --list --unsorted

# Development bootstrap --------------------------------------------------------

# Check the platform, Nix, Homebrew or pacman and the SDK; downloads nothing
[group('bootstrap')]
foundation:
    scripts/bootstrap/dev-bootstrap.sh --check-foundation

# Report what apply would install (--only, --all, --json)
[group('bootstrap')]
plan *args:
    scripts/bootstrap/dev-bootstrap.sh plan "$@"

# Install the missing baseline releases
[group('bootstrap')]
apply *args:
    scripts/bootstrap/dev-bootstrap.sh apply "$@"

# Verify the exact declared baseline
[group('bootstrap')]
verify *args:
    scripts/bootstrap/dev-bootstrap.sh verify "$@"

# Verify the selected environment instead of the declared releases
[group('bootstrap')]
health *args:
    scripts/bootstrap/dev-bootstrap.sh verify --health "$@"

# List the installed releases the baseline retired; --yes removes them
[group('bootstrap')]
prune *args:
    scripts/bootstrap/dev-bootstrap.sh prune "$@"

# Updates ----------------------------------------------------------------------

# Compare the runtime baseline with its upstreams; --apply advances patches
[group('updates')]
baseline *args='--check':
    scripts/updates/update-runtime-baseline.py "$@"

# Compare the tag and commit pins in flake.nix with upstream; --apply moves them
[group('updates')]
inputs *args='--check':
    scripts/updates/update-pinned-inputs.sh "$@"

# Refresh flake.lock: every input, or the named ones
[group('updates')]
lock *inputs:
    nix flake update "$@"

# Compare the SketchyBar package with its latest release; --apply moves it
[group('updates')]
sketchybar *args='--check':
    scripts/updates/update-sketchybar.sh "$@"

# Compare the yabai package with its latest signed release; --apply moves it
[group('updates')]
yabai *args='--check':
    scripts/updates/update-yabai.sh "$@"

# Checks -----------------------------------------------------------------------

# Formatting, lint, policies and script tests, as CI runs them
[group('checks')]
check:
    nix develop --impure --expr '{{ ci_shell }}' --command bash scripts/checks/run-all.sh

# Evaluate every flake output for both systems without building
[group('checks')]
flake-check:
    nix flake check --no-build --all-systems --show-trace

# Bootstrap contracts: source fixtures, or the packaged executor's tests
[group('checks')]
test-bootstrap phase='source':
    bash scripts/bootstrap/ci-development-bootstrap.sh "$1"

# The complete Zsh suite
[group('checks')]
test-zsh:
    home/shells/zsh/config/tests/run-all.zsh --full

# Workstation security regressions
[group('checks')]
test-security:
    python3 scripts/tests/security_regressions.py

# Every local check before pushing
[group('checks')]
ci: check flake-check (test-bootstrap 'source') (test-bootstrap 'package') test-zsh
    git diff --check

# Audits -----------------------------------------------------------------------

# Which manager owns each command; run from an interactive login shell
[group('audits')]
audit-ownership *args:
    scripts/audits/audit-package-ownership.sh "$@"

# Live symlinks into this repository against the out-of-store allowlist
[group('audits')]
audit-live:
    scripts/audits/audit-live-config.sh

# System -----------------------------------------------------------------------

# Build the complete configuration without activating it
[group('system')]
[macos]
build:
    nix build '.#darwinConfigurations.{{ darwin }}.system' --no-link

# Build the complete configuration without activating it
[group('system')]
[linux]
build:
    nix build '.#homeConfigurations."{{ linux }}".activationPackage' --no-link

# Build, then activate the same configuration
[confirm('Activate the built system configuration?')]
[group('system')]
[macos]
switch: build
    sudo darwin-rebuild switch --flake '.#{{ darwin }}'

# Build, then activate the same configuration with a fresh backup suffix
[confirm('Activate the built Home Manager configuration?')]
[group('system')]
[linux]
switch: build
    home-manager switch --flake '.#{{ linux }}' -b "hm-$(date +%Y%m%d-%H%M%S)"
