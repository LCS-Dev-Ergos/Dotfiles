# Dotfiles

Personal dotfiles for macOS and Linux, managed declaratively with [Nix](https://nixos.org/) — [nix-darwin](https://github.com/LnL7/nix-darwin) for system-level macOS configuration and [Home Manager](https://github.com/nix-community/home-manager) for per-application configuration on both platforms. This repo previously used [GNU Stow](https://www.gnu.org/software/stow/) to symlink one package per tool; that workflow has been fully replaced (see [Migrating from GNU Stow](#migrating-from-gnu-stow)).

![My MacOS Rice](assets/Screenshot-LCS.Dev.webp)

## Table of Contents

- [Dotfiles](#dotfiles)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
    - [Clone the Repository](#clone-the-repository)
    - [macOS (nix-darwin + Home Manager)](#macos-nix-darwin--home-manager)
    - [Linux (standalone Home Manager)](#linux-standalone-home-manager)
  - [Directory Structure](#directory-structure)
  - [What's Managed Where](#whats-managed-where)
  - [State Boundaries](#state-boundaries)
  - [Package Ownership and Homebrew Drift](#package-ownership-and-homebrew-drift)
  - [Verification](#verification)
  - [Migrating from GNU Stow](#migrating-from-gnu-stow)
  - [Contributing](#contributing)
  - [License](#license)

## Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled (`experimental-features = nix-command flakes`).
- **macOS**: [nix-darwin](https://github.com/LnL7/nix-darwin) installed.
- **Linux**: [Home Manager](https://github.com/nix-community/home-manager) installed standalone — no NixOS required, the host's own package manager stays responsible for the OS itself.

## Installation

### Clone the Repository

```bash
git clone https://github.com/XtremeXSPC/Dotfiles.git ~/Dotfiles
cd ~/Dotfiles
```

### macOS (nix-darwin + Home Manager)

Validate first — this only evaluates and builds, it never touches the live system:

```bash
darwin-rebuild build --flake .#LCSMacBook-Pro
```

The account name and home directory are explicit host facts in `flake.nix`, so
evaluation remains pure and does not require `--impure`. Once the build is
clean, activate it:

```bash
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

This applies every Home Manager-managed dotfile, the declared Homebrew inventory (taps/casks/formulae), and the Dock/Finder/trackpad system defaults, and reruns on every subsequent switch.

### Linux (standalone Home Manager)

```bash
home-manager switch --flake '.#lcs-dev@lcs-legion-arch'
```

Only one Linux host is currently defined (`lcs-legion-arch`, Arch Linux, `x86_64-linux`), and it is **written but unverified** — there is no physical or remote access to actually build or switch it yet. Treat it as a structural reference, not a confirmed-working config.

## Directory Structure

```dir
Dotfiles/
├── flake.nix              # Flake entry point: darwin + home-manager outputs
├── flake.lock
├── hosts/
│   ├── lcs-macbook-pro/
│   │   ├── darwin.nix     # Host-specific: stateVersion, hostPlatform
│   │   └── home.nix       # Host-specific: username, homeDirectory, imports
│   └── lcs-legion-arch/
│       └── home.nix       # Same shape, for the Linux host
├── darwin/
│   ├── default.nix        # Shared nix-darwin config: nix.gc, system.defaults, users
│   └── homebrew.nix       # Declarative Homebrew: taps, casks, formulae
└── home/
    ├── default.nix        # Shared Home Manager policy and stateVersion
    ├── common.nix         # Platform-neutral application imports
    ├── darwin.nix         # macOS-only application imports
    ├── linux.nix          # Linux/Wayland-only application imports
    ├── out-of-store-allowlist.tsv
    ├── package-ownership-allowlist.tsv
    ├── git/                # One folder per tool, each with its own default.nix
    ├── zsh/
    └── ...                 # kitty, neovim, tmux, starship, fish, nushell, etc.
```

Each application's Nix glue and its actual config content live together in the same folder, rather than mirroring `$HOME`'s layout the way the old Stow packages did.

## What's Managed Where

- **`darwin/`** — system-level, macOS only: Homebrew inventory, Dock/Finder/trackpad defaults, Nix garbage collection, and the account mapping Home Manager needs.
- **`home/`** — per-application Home Manager modules, shared across both hosts where a tool exists on both platforms. Platform-specific behavior is gated with `lib.mkIf pkgs.stdenv.isDarwin` / `pkgs.stdenv.isLinux` inside the shared module rather than duplicated per host.
- **zsh is config-only**: everything under `home/zsh/` is Nix/Home Manager-managed, but the `zsh` binary itself is still Homebrew-managed for now — a deliberate, staged decision.

## State Boundaries

Static configuration is deployed from the Nix store wherever the application
can consume read-only files. Legitimate writable state belongs outside Git and
the store: persistent state under `XDG_STATE_HOME`, disposable data under
`XDG_CACHE_HOME`, and application data under `XDG_DATA_HOME`.

The remaining applications that must write through a Home Manager-managed
configuration path are listed in `home/out-of-store-allowlist.tsv`, including
the writer, sensitivity, rollback behavior, and the condition for retiring the
exception. `scripts/check-out-of-store-allowlist.sh` rejects an unregistered
`mkOutOfStoreSymlink` or a stale registry entry. Fish is one example of an
explicit boundary: its tracked `fish_variables` snapshot is only a first-run
seed, while the live file is private state under `XDG_STATE_HOME` and is never
overwritten by activation.

Back up `XDG_STATE_HOME` and `XDG_DATA_HOME` as user data; a Nix generation
rollback intentionally does not erase or rewind them. `XDG_CACHE_HOME` is
disposable and should be reproducible from declared configuration plus normal
application startup.

After activation, `scripts/audit-live-config.sh` performs a read-only audit of
the live home directory. It reports broken configuration links, links into the
checkout that lack a registered exception, and changes beneath a registered
repository-backed target. A newly implemented migration can therefore remain
visible as pending until its replacement generation has actually been
activated.

## Package Ownership and Homebrew Drift

Homebrew remains responsible for macOS applications and packages that need its
ecosystem, while Nix owns the portable command-line baseline and development
toolchains that benefit from reproducibility. Activation deliberately uses
`homebrew.onActivation.cleanup = "none"`: a switch may install a missing
declaration, but it never uninstalls an undeclared package.

Run the read-only ownership audit from an interactive login shell:

```bash
scripts/audit-package-ownership.sh
```

The audit evaluates the actual `homebrew.brews`, `homebrew.casks`, and
`homebrew.taps` options from the Darwin flake, then compares them with the live
installation. Homebrew's transitive formula dependencies are counted but are
not mislabeled as top-level drift; only formulae recorded by Homebrew as
explicitly requested are candidates for an `UNDECLARED FORMULA` finding.
Potential removals include their installed reverse dependencies, so a
`BLOCKED` result can be investigated without attempting an uninstall.

The same command examines executable precedence across the active `PATH`.
Unexpected cases where a Homebrew command precedes an available Nix command
are failures. Deliberate dual ownership belongs in
`home/package-ownership-allowlist.tsv`, with the expected winner and the
operational reason. Use `--verbose` to list every benign overlap where Nix
already wins. The audit never installs, upgrades, removes, taps, or untaps
anything; a nonzero result means the report contains drift or a precedence
problem to review.

## Verification

The flake exposes a lockfile-pinned `ci` development shell for Nix formatting
and policy checks. Run the same core checks used by CI with:

```bash
nix develop .#ci --command bash -euo pipefail -c '
  mapfile -t nix_files < <(find flake.nix darwin home hosts -type f -name "*.nix" | sort)
  nixfmt --check "${nix_files[@]}"
  statix check .
  deadnix --fail flake.nix darwin home hosts
  bash scripts/check-out-of-store-allowlist.sh
  bash scripts/check-package-ownership-policy.sh
  bash scripts/check-declared-secrets.sh
  bash scripts/tests/run.sh
  shellcheck scripts/*.sh scripts/tests/*.sh
'
nix flake check --no-build --all-systems --show-trace
home/zsh/config/tests/run-all.zsh --full
git diff --check
```

On macOS, finish with a complete non-activating build before switching:

```bash
nix build .#darwinConfigurations.LCSMacBook-Pro.system --no-link
```

The Linux output is evaluated on CI, but it remains structurally verified only
until it can be built, activated, exercised, and rolled back on the real host.

## Migrating from GNU Stow

This repo used to be one GNU Stow package per tool (`zsh/`, `kitty/`, `nvim/`, ...), each mirroring `$HOME`'s layout so `stow <package>` could symlink it in. That workflow, including the old Stow scaffolding scripts, has been fully retired in favor of the Nix/Home Manager structure above. If you're looking at an older clone or fork that still uses Stow, it predates this migration.

## Contributing

Contributions are welcome! Feel free to open an issue or submit a pull request if you have suggestions for improving this repository.

## License

This repository is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
