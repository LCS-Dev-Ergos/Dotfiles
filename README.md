# Dotfiles

Declarative workstation configuration for macOS and Linux, built as a Nix
flake. [nix-darwin](https://github.com/nix-darwin/nix-darwin) manages the macOS
system layer, [Home Manager](https://github.com/nix-community/home-manager)
manages application configuration on both platforms, and a packaged development
bootstrap installs language runtimes through their native version managers at
exact, declared versions. Revisions before the Nix migration used one GNU Stow
package per tool; that layout is retired.

![macOS desktop with SketchyBar, kitty, tmux, Neovim, fastfetch and btop](assets/Screenshot-LCS.Dev.webp)

## Contents

- [Architecture Overview](#architecture-overview)
- [Supported Platforms](#supported-platforms)
- [Prerequisites](#prerequisites)
- [Bootstrap and Installation](#bootstrap-and-installation)
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

The development bootstrap in `home/dev/bootstrap/` is packaged as the
`dev-bootstrap` command and runs only when invoked. Neither activation nor
shell startup provisions language runtimes.

### Ownership Model

Each class of software has one owner:

| Owner | Scope |
| --- | --- |
| Nix | Portable command-line baseline and the development toolchains that benefit from reproducibility |
| Home Manager | Application configuration on both platforms |
| Homebrew (macOS) | Applications and packages that need the Homebrew ecosystem; nix-darwin declares the inventory of taps, formulae and casks |
| Distribution (Linux) | Operating system, graphics drivers, graphical runtimes and login infrastructure |
| Native ecosystem managers | Language runtimes, their upgrades and project selections: fnm, pyenv, opam, rbenv, rustup, GHCup, elan, SDKMAN and juliaup |

Ecosystem managers use their canonical native installation on macOS and on
Arch-based Linux; shared configuration and shell integration stay with Home
Manager. The installation intent is declared in `home/dev/native-managers.nix`
and can be inspected with `nix eval --json --file home/dev/native-managers.nix`.
Each configuration's `nativeFnmReady` flag selects whether FNM still comes from
Nix or from the native installation. A consumer without native managers, such
as NixOS, selects the `nixpkgs` runtime backend explicitly.

Home Manager manages everything under `home/shells/zsh/`. On macOS the login
shell is the Nix `zsh`, set through `users.users.<name>.shell` and recorded as
the generation-stable `/run/current-system/sw/bin/zsh`. Homebrew's `zsh`
remains declared, and every stock macOS shell stays in `/etc/shells` for
recovery.

Activation sets `homebrew.onActivation.cleanup = "none"`: a switch installs
missing declarations and never uninstalls an undeclared package.

`scripts/audits/audit-package-ownership.sh`, run from an interactive login
shell, compares the evaluated `homebrew.brews`, `homebrew.casks` and
`homebrew.taps` with the live installation and checks command precedence across
`PATH`:

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
belong in the compiler package. Tcl/Tk 8 is declared for tkinter. The
development bootstrap declares build dependencies per ecosystem in
`home/dev/native-managers.nix` and installs them through Homebrew or pacman, so
it also works before nix-darwin is active. A project that needs a fully pinned
Python environment uses a development shell in its own flake instead.

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
`scripts/checks/check-out-of-store-allowlist.sh` rejects an unregistered
`mkOutOfStoreSymlink` and stale entries. Fish shows the boundary: its tracked
`fish_variables` file is only a first-run seed, while the live file is private
state under `XDG_STATE_HOME` that activation never overwrites.

After activation, `scripts/audits/audit-live-config.sh` audits the live home
directory read-only for broken links, unregistered links into the checkout and
changes beneath registered targets. A migration therefore stays visible as
pending until the generation that implements it is active.

## Supported Platforms

| Platform | Nix system | Configuration | Reference output | Entry point |
| --- | --- | --- | --- | --- |
| macOS on Apple Silicon | `aarch64-darwin` | nix-darwin with the Home Manager module | `darwinConfigurations."LCSMacBook-Pro"` | `hosts/lcs-macbook-pro/` |
| Arch-based Linux, reference distribution CachyOS | `x86_64-linux` | Standalone Home Manager | `homeConfigurations."lcs-dev@LCS.Dev-Legion-Cachy"` | `hosts/lcs-dev-legion-cachy/` |

Output names are the attribute names of the reference configurations. The
account name, home directory and checkout path are declared once per platform
in `flake.nix` and reach modules as arguments; shared modules never hard-code
them.

On Linux the distribution owns the operating system and graphical runtimes,
and Home Manager runs standalone, so NixOS is not required. The retired Arch
entry point and the HyDE assets remain in the repository without a flake
output or desktop deployment.

## Prerequisites

| Requirement | macOS | Linux |
| --- | --- | --- |
| Nix | Flakes enabled: `experimental-features = nix-command flakes` | Same |
| Package manager | Homebrew; nix-darwin manages its inventory but does not install it | pacman; the distribution remains responsible for the operating system |
| Configuration tool | [nix-darwin](https://github.com/nix-darwin/nix-darwin) | None in advance: the first activation runs the built generation's `activate` script |
| Build prerequisites | Command Line Tools for Xcode, whose Apple SDK the Nix compilers target; the bootstrap installs the declared build dependencies through Homebrew | The bootstrap installs the declared build dependencies through pacman |

On Apple Silicon, `scripts/bootstrap/dev-bootstrap.sh --install-foundation`
installs a missing Homebrew and Nix (see
[Development Bootstrap](#development-bootstrap)).

## Bootstrap and Installation

Installation has two independent stages. The development bootstrap installs
language runtimes and can run before any configuration is active. Activation
applies the system and Home Manager configuration. Neither stage invokes the
other.

### Clone

```bash
git clone https://github.com/LCS-Dev-Ergos/Dotfiles.git ~/Dotfiles
cd ~/Dotfiles
```

### Development Bootstrap

`scripts/bootstrap/dev-bootstrap.sh` starts under the system Bash, before Nix
is available, and delegates to the packaged executor. The executor is built
through `scripts/bootstrap/development-bootstrap.nix` from the nixpkgs revision
in `flake.lock`, without evaluating the flake's other inputs. Once the
configuration is active, the [Justfile](Justfile) runs the same operations:
`just plan`, `just apply`, `just verify`, `just health` and `just prune`.

| Invocation | Effect |
| --- | --- |
| `scripts/bootstrap/dev-bootstrap.sh --check-foundation` | Checks the platform, Nix daemon, Homebrew or pacman and the Apple SDK; downloads nothing |
| `scripts/bootstrap/dev-bootstrap.sh --install-foundation plan --json` | Apple Silicon only: installs a missing Homebrew and Nix, then plans |
| `scripts/bootstrap/dev-bootstrap.sh plan` | Default operation: reports what `apply` would change |
| `scripts/bootstrap/dev-bootstrap.sh apply --only node` | Installs the selected ecosystems |
| `scripts/bootstrap/dev-bootstrap.sh verify` | Verifies the exact declared baseline; `--health` checks the selected environment instead |
| `scripts/bootstrap/dev-bootstrap.sh prune` | Lists the installed releases the baseline retired; `--yes` removes them |

- Versions are declared in `home/dev/runtime-baseline.nix`. After the initial
  installation, each ecosystem manager owns upgrades, additional releases and
  project selection.
- `scripts/updates/update-runtime-baseline.py --check` (`just baseline`)
  compares every declared release and installer with its upstream, and
  `--apply` advances patch releases and records each replaced one as
  retired; a weekly workflow runs the check. `prune` then removes the retired
  releases a host still has. The procedure is in
  [home/dev/README.md](home/dev/README.md#keeping-the-baseline-current).
- A rerun adds missing baseline entries and leaves later upgrades, additional
  releases and project selections in place.
- Foundation installation runs only the installers for missing foundations:
  the pinned official Homebrew installer, then the official Nix multi-user
  installer. On Linux, Nix and pacman must already be present.
- The bootstrap never activates nix-darwin or Home Manager and never installs
  desktop applications.

The [development configuration guide](home/dev/README.md#clean-host-entry) and
the [bootstrap reference](home/dev/bootstrap/README.md) cover privileges,
download boundaries and the adapter model.

### macOS Activation

Build before every switch. The build evaluates and compiles the complete
system without changing the running one, and no CI runner performs it:

```bash
nix build .#darwinConfigurations.LCSMacBook-Pro.system --no-link
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

`just build` runs the first command; `just switch` runs both, in order, after
a confirmation.

`--no-link` avoids the `result` symlink, a garbage-collection root that would
keep the generation alive across `nix.gc` runs. The account name and home
directory are declared in `flake.nix`, so evaluation is pure and needs no
`--impure`. A switch applies the Home Manager configuration, the declared
Homebrew inventory and the Dock, Finder and trackpad defaults.

### Linux Activation

```bash
nix build '.#homeConfigurations."lcs-dev@LCS.Dev-Legion-Cachy".activationPackage' --no-link
```

Standalone Home Manager distributes application settings and command-line
tools. Common Linux applications and the selected Hyprland desktop are
separate imports, and KDE Plasma remains available as a separate session. The
[CachyOS configuration guide](hosts/lcs-dev-legion-cachy/README.md) covers the
native dependencies, backup, activation, session checks and rollback. A
successful build validates the Nix closure; desktop behavior is verified in a
running session with the native runtime.

## Module Organization

```dir
Dotfiles/
├── flake.nix                  # Inputs and the darwin and Home Manager outputs
├── flake.lock
├── Justfile                   # Maintenance commands; `just` lists them
├── scripts/
│   ├── bootstrap/             # Clean-host entry, its CI entry, flake-free Nix shells
│   ├── checks/                # Repository policy checks; run-all.sh is CI's check set
│   ├── audits/                # Live-home and package-ownership audits
│   ├── updates/               # Updaters for flake pins, packages and the runtime baseline
│   └── tests/                 # Regression tests for the scripts and the workstation
├── hosts/
│   ├── lcs-macbook-pro/
│   │   ├── darwin.nix         # Platform, account and login shell, stateVersion, system defaults
│   │   └── home.nix           # username, homeDirectory, imports
│   ├── lcs-dev-legion-cachy/
│   │   └── home.nix           # CachyOS: common applications and selected desktop modules
│   └── lcs-legion-arch/
│       └── home.nix           # Retired Arch entry point, without a flake output
├── darwin/
│   ├── default.nix            # Nix GC and store optimisation, fonts, /etc, unfree policy
│   └── homebrew.nix           # Declared taps, formulae and casks
└── home/
    ├── default.nix            # Shared Home Manager policy and stateVersion
    ├── common.nix             # Platform-neutral application imports
    ├── darwin.nix             # macOS-only application imports
    ├── linux.nix              # Linux application imports shared by KDE and Hyprland
    ├── out-of-store-allowlist.tsv
    ├── package-ownership-allowlist.tsv
    ├── cli/                   # bat, btop, cli-tools, git, lazygit, tealdeer
    ├── desktop/               # Window managers and bars (platform-only modules)
    ├── dev/                   # Toolchains and per-language tooling
    ├── editors/               # neovim, doom, zed, vscode, markdown
    ├── file-managers/         # yazi, ranger, nnn, ueberzugpp
    ├── multiplexers/          # tmux, zellij, herdr
    ├── ricing/                # fastfetch, neofetch, cava
    ├── shells/                # zsh, fish, nushell, starship, oh-my-posh, atuin
    └── terminals/             # kitty, ghostty, wezterm, alacritty
```

Module conventions:

- Modules are grouped by category, one directory per application with its own
  `default.nix`. Nix glue and the application's configuration files live
  together instead of mirroring the layout of `$HOME`.
- A category's `default.nix` imports only cross-platform modules and is
  imported by `home/common.nix`. Platform-only modules are imported one by one
  from `home/darwin.nix` or `home/linux.nix`, so `desktop/` has no
  `default.nix`.
- Platform differences are gated inside the shared module with
  `lib.mkIf pkgs.stdenv.hostPlatform.isDarwin` or
  `pkgs.stdenv.hostPlatform.isLinux`, never duplicated per configuration.

### StatWell Status Service

The shared StatWell user service supplies SketchyBar's CPU, network-rate,
battery and Homebrew widgets and Kitty's memory, load, disk and battery
segments. Its package and Home Manager module are pinned as a flake input. The
[StatWell consumer guide](home/cli/statwell/README.md) covers activation,
checks, Linux behavior and rollback. Git history retains the legacy SketchyBar
providers for rollback.

## Validation and CI

### Local Checks

`scripts/checks/run-all.sh` is the set of formatting, lint and policy checks
CI runs: Nix, workflow and Python formatting and lint, the state-boundary,
package-ownership and secret policies, the script regression tests and
ShellCheck. It runs inside the locked `ci` shell of
`scripts/bootstrap/development-bootstrap.nix`, which provides every tool.
`just ci` runs every local check in order:

| Recipe | Command |
| --- | --- |
| `just check` | `scripts/checks/run-all.sh` in the locked `ci` shell |
| `just flake-check` | `nix flake check --no-build --all-systems --show-trace` |
| `just test-bootstrap`, `just test-bootstrap package` | `scripts/bootstrap/ci-development-bootstrap.sh source`, `package` |
| `just test-zsh` | `home/shells/zsh/config/tests/run-all.zsh --full` |

`just ci` ends with `git diff --check`.

`nix flake check --no-build` proves that every output evaluates on both systems
but runs none of the checks. CI builds the check derivations a runner can
afford: `cpp-tools`, whose check phase is its Zsh test suite, on both systems,
and `llvm-darwin-toolchain` on macOS, whose smoke test compiles, links and runs
real Clang and GCC binaries to verify the host SDK selection, the deployment
target, the Apple linker selection and the relocated runtime libraries.

No runner builds `darwin-configuration`, the complete system. The build in
[macOS Activation](#macos-activation) is the first complete build, so it runs
before every switch.

CI evaluates the Linux output. Build it before activation; login, rendering,
portals, wallet access and rollback are verified in a running session.

### Workflows

| Workflow | Trigger | Runners | Coverage |
| --- | --- | --- | --- |
| `zsh-validate.yml` | Push and pull request on configuration paths | Ubuntu 24.04, macOS 26, latest Ubuntu and macOS | Formatting, lint and policy checks; pinned-toolchain freshness; flake evaluation for both systems; `cpp-tools` and `llvm-darwin-toolchain` builds; the Zsh suite on Linux and macOS |
| `development-bootstrap.yml` | Push and pull request on bootstrap paths | Ubuntu 24.04 (x86_64), macOS 15 (arm64) | Bootstrap source contracts, ownership checks and the packaged executor's tests |
| `development-bootstrap-native.yml` | Manual dispatch; every adapter by default, in five jobs per platform | macOS 15, Arch Linux container on Ubuntu 24.04 | Real managers, downloads and builds from an empty root; the real home stays unchanged; a rerun installs nothing; optionally manager updates, package upgrades, user evolution and interruptions |

## Contributing

Issues and pull requests are accepted on GitHub. A change follows the module
conventions above and passes the [local checks](#local-checks).

## License

Released under the MIT License. See [LICENSE](LICENSE).
