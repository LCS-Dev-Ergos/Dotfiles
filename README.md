# Dotfiles

Declarative workstation configuration for macOS and Linux, built as a Nix
flake. [nix-darwin](https://github.com/nix-darwin/nix-darwin) manages the macOS
system layer, and [Home Manager](https://github.com/nix-community/home-manager)
manages application configuration on both platforms. Revisions before the Nix
migration used one GNU Stow package per tool; that layout is retired.

![macOS desktop with SketchyBar, kitty, tmux, Neovim, fastfetch and btop](assets/Screenshot-LCS.Dev.webp)

## Contents

- [Architecture Overview](#architecture-overview)
- [Supported Platforms](#supported-platforms)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Module Organization](#module-organization)
- [Validation and CI](#validation-and-ci)
- [Contributing](#contributing)
- [License](#license)

## Architecture Overview

The flake composes four layers. Platform differences are resolved inside
shared modules instead of being copied per configuration.

| Layer | Location | Responsibility |
| --- | --- | --- |
| Flake | `flake.nix`, `flake.lock` | Pinned inputs and the configuration outputs |
| System (macOS) | `darwin/` | nix-darwin policy shared by every macOS configuration: Homebrew inventory, Nix garbage collection and store optimisation, fonts, generated `/etc` entries and the unfree-package predicate |
| User | `home/` | Home Manager modules, one per application, shared by both platforms |
| Entry point | `hosts/<name>/` | Module selection and the facts of one configuration: platform, account mapping, login shell, state version, system defaults |

### Ownership Model

Homebrew owns macOS applications and the packages that need its ecosystem;
nix-darwin declares that inventory of taps, formulae and casks. Nix owns the
portable command-line baseline and the development toolchains that benefit
from reproducibility, and Home Manager owns application configuration.

Home Manager manages everything under `home/zsh/`. On macOS the login shell is
the Nix `zsh`, set through `users.users.<name>.shell` and recorded as the
generation-stable `/run/current-system/sw/bin/zsh`. Homebrew's `zsh` remains
declared, and every stock macOS shell stays in `/etc/shells` for recovery.

Activation sets `homebrew.onActivation.cleanup = "none"`: a switch installs
missing declarations and never uninstalls an undeclared package.

`scripts/audit-package-ownership.sh`, run from an interactive login shell,
compares the evaluated `homebrew.brews`, `homebrew.casks` and `homebrew.taps`
with the live installation and checks command precedence across `PATH`:

- Only formulae that Homebrew records as explicitly requested can be reported
  as undeclared. Transitive dependencies are counted, and each potential
  removal lists its installed reverse dependencies.
- A Homebrew command that precedes an available Nix command is a failure unless
  `home/package-ownership-allowlist.tsv` records the overlap, its expected
  winner and the reason. `--verbose` also lists the overlaps that Nix wins.
- The audit never installs, upgrades, removes, taps or untaps anything. A
  nonzero exit status means the report contains drift or a precedence problem.

On macOS, pyenv's `python-build` compiles CPython with the Nix compiler drivers
against Apple's SDK. The external libraries it links against are declared in
`darwin/homebrew.nix` and found through Homebrew and pkg-config; they do not
belong in the compiler package. Tcl/Tk 8 is declared for tkinter. A project
that needs a fully pinned Python environment uses a development shell in its
own flake instead.

### Compiler Toolchains

A running terminal, editor or tmux server keeps the `CC` and `CXX` values it
started with, which can name an old store path after a toolchain change.
Restart the parent application, or reset both variables in the current shell
before rebuilding:

```sh
export CC="/etc/profiles/per-user/$USER/bin/clang"
export CXX="/etc/profiles/per-user/$USER/bin/clang++"
```

`get_toolchain_sdk_support --all` tests default header search paths only. A
`missing` result does not mean a library needs installing: Apple's `ffi.h`, for
example, needs the SDK's `usr/include/ffi` include path, which CPython's
configure supplies. Link and runtime checks are separate.

### State Boundaries

Static configuration is deployed from the Nix store wherever the application
accepts read-only files. Writable state stays outside Git and the store:

| Location | Content | Generation rollback |
| --- | --- | --- |
| `XDG_STATE_HOME` | Persistent application state | Not rewound; back up as user data |
| `XDG_DATA_HOME` | Application data | Not rewound; back up as user data |
| `XDG_CACHE_HOME` | Disposable data | Reproducible from configuration and normal startup |

Applications that must write through a managed configuration path are
registered in `home/out-of-store-allowlist.tsv`, with the writer, sensitivity,
rollback behavior and retirement condition of each exception.
`scripts/check-out-of-store-allowlist.sh` rejects an unregistered
`mkOutOfStoreSymlink` and stale entries. Fish shows the boundary: its tracked
`fish_variables` file is only a first-run seed, while the live file is private
state under `XDG_STATE_HOME` that activation never overwrites.

After activation, `scripts/audit-live-config.sh` audits the live home directory
read-only for broken links, unregistered links into the checkout and changes
beneath registered targets. A migration therefore stays visible as pending
until the generation that implements it is active.

## Supported Platforms

| Platform | Nix system | Configuration | Reference output | Entry point |
| --- | --- | --- | --- | --- |
| macOS on Apple Silicon | `aarch64-darwin` | nix-darwin with the Home Manager module | `darwinConfigurations."LCSMacBook-Pro"` | `hosts/lcs-macbook-pro/` |
| Arch Linux | `x86_64-linux` | Standalone Home Manager | `homeConfigurations."lcs-dev@lcs-legion-arch"` | `hosts/lcs-legion-arch/` |

Output names are the attribute names of the reference configurations. The
account name and home directory are declared in `flake.nix` and reach modules
as arguments; shared modules never hard-code them. The Linux configuration is
experimental: CI evaluates it, but its build and activation are not validated.

## Prerequisites

| Requirement | macOS | Linux |
| --- | --- | --- |
| Nix | Flakes enabled: `experimental-features = nix-command flakes` | Same |
| Package manager | Homebrew; nix-darwin manages its inventory but does not install it | The distribution's package manager, which remains responsible for the operating system |
| Configuration tool | [nix-darwin](https://github.com/nix-darwin/nix-darwin) | [Home Manager](https://github.com/nix-community/home-manager) in standalone mode; NixOS is not required |
| Build prerequisites | Command Line Tools for Xcode, whose Apple SDK the Nix compilers target | Not applicable |

## Installation

### Clone

```bash
git clone https://github.com/LCS-Dev-Ergos/Dotfiles.git ~/Dotfiles
cd ~/Dotfiles
```

### macOS Activation

Build before every switch. The build evaluates and compiles the complete
system without changing the running one, and no CI runner performs it:

```bash
nix build .#darwinConfigurations.LCSMacBook-Pro.system --no-link
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

`--no-link` avoids the `result` symlink, a garbage-collection root that would
keep the generation alive across `nix.gc` runs. The account name and home
directory are declared in `flake.nix`, so evaluation is pure and needs no
`--impure`. A switch applies the Home Manager configuration, the declared
Homebrew inventory and the Dock, Finder and trackpad defaults.

### Linux Activation

```bash
home-manager switch --flake '.#lcs-dev@lcs-legion-arch'
```

## Module Organization

```dir
Dotfiles/
├── flake.nix                  # Inputs and the darwin and Home Manager outputs
├── flake.lock
├── hosts/
│   ├── lcs-macbook-pro/
│   │   ├── darwin.nix         # Platform, account and login shell, stateVersion, system defaults
│   │   └── home.nix           # username, homeDirectory, imports
│   └── lcs-legion-arch/
│       └── home.nix           # The same shape for the Linux configuration
├── darwin/
│   ├── default.nix            # Nix GC and store optimisation, fonts, /etc, unfree policy
│   └── homebrew.nix           # Declared taps, formulae and casks
└── home/
    ├── default.nix            # Shared Home Manager policy and stateVersion
    ├── common.nix             # Platform-neutral application imports
    ├── darwin.nix             # macOS-only application imports
    ├── linux.nix              # Linux and Wayland application imports
    ├── out-of-store-allowlist.tsv
    ├── package-ownership-allowlist.tsv
    ├── git/                   # One directory per application, each with its own default.nix
    ├── zsh/
    └── ...                    # kitty, neovim, tmux, starship, fish, nushell and others
```

Module conventions:

- One directory per application, with its own `default.nix`. Nix glue and the
  application's configuration files live together instead of mirroring the
  layout of `$HOME`.
- Platform differences are gated inside the shared module with
  `lib.mkIf pkgs.stdenv.hostPlatform.isDarwin` or
  `pkgs.stdenv.hostPlatform.isLinux`, never duplicated per configuration.

## Validation and CI

### Local Checks

The flake exposes a lockfile-pinned `ci` development shell for Nix formatting
and policy checks. The core checks that CI runs:

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

`nix flake check --no-build` proves that every output evaluates on both systems
but runs none of the checks. CI builds the check derivations a runner can
afford: `cpp-tools`, whose check phase is its Zsh test suite, on both systems,
and `llvm-darwin-toolchain` on macOS, whose smoke test compiles, links and runs
real Clang and GCC binaries to verify the host SDK selection, the deployment
target, the Apple linker selection and the relocated runtime libraries.

No runner builds `darwin-configuration`, the complete system. The build in
[macOS Activation](#macos-activation) is the first complete build, so it runs
before every switch.

## Contributing

Issues and pull requests are accepted on GitHub. A change follows the module
conventions above and passes the [local checks](#local-checks).

## License

Released under the MIT License. See [LICENSE](LICENSE).
