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
- [Contributing](#contributing)
- [License](#license)

## Architecture Overview

The flake composes four layers. Platform differences are resolved inside
shared modules instead of being copied per configuration.

| Layer | Location | Responsibility |
| --- | --- | --- |
| Flake | `flake.nix`, `flake.lock` | Pinned inputs and the configuration outputs |
| System (macOS) | `darwin/` | nix-darwin policy: Homebrew inventory, Dock, Finder and trackpad defaults, Nix garbage collection and the account mapping Home Manager needs |
| User | `home/` | Home Manager modules, one per application, shared by both platforms |
| Entry point | `hosts/<name>/` | Module selection and the facts of one configuration, such as its state version and platform |

### Ownership Model

nix-darwin declares the Homebrew inventory: taps, formulae and casks. Home
Manager owns application configuration. The zsh configuration under
`home/zsh/` is managed by Home Manager, while the `zsh` executable comes from
Homebrew.

## Supported Platforms

| Platform | Nix system | Configuration | Reference output | Entry point |
| --- | --- | --- | --- | --- |
| macOS on Apple Silicon | `aarch64-darwin` | nix-darwin with the Home Manager module | `darwinConfigurations."LCSMacBook-Pro"` | `hosts/LCSMacBook-Pro/` |
| Arch Linux | `x86_64-linux` | Standalone Home Manager | `homeConfigurations."lcs-dev@lcs-legion-arch"` | `hosts/lcs-legion-arch/` |

Output names are the attribute names of the reference configurations. The
Linux configuration is experimental: it shares the application modules, but
its build and activation are not validated.

## Prerequisites

| Requirement | macOS | Linux |
| --- | --- | --- |
| Nix | Flakes enabled: `experimental-features = nix-command flakes` | Same |
| Package manager | Homebrew; nix-darwin manages its inventory but does not install it | The distribution's package manager, which remains responsible for the operating system |
| Configuration tool | [nix-darwin](https://github.com/nix-darwin/nix-darwin) | [Home Manager](https://github.com/nix-community/home-manager) in standalone mode; NixOS is not required |

## Installation

### Clone

```bash
git clone https://github.com/XtremeXSPC/Dotfiles.git ~/Dotfiles
cd ~/Dotfiles
```

### macOS Activation

Build before switching. `darwin-rebuild build` evaluates and builds the
configuration without changing the running system:

```bash
darwin-rebuild build --flake .#LCSMacBook-Pro --impure
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro --impure
```

`--impure` is required: nix-darwin reads the macOS account state
(`system.primaryUser` and the account's home directory), which a pure
evaluation cannot see. A switch applies the Home Manager configuration, the
declared Homebrew inventory and the Dock, Finder and trackpad defaults.

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
│   ├── LCSMacBook-Pro/
│   │   ├── darwin.nix         # stateVersion, hostPlatform
│   │   └── home.nix           # username, homeDirectory, imports
│   └── lcs-legion-arch/
│       └── home.nix           # The same shape for the Linux configuration
├── darwin/
│   ├── default.nix            # Shared nix-darwin policy: nix.gc, system.defaults, users
│   └── homebrew.nix           # Declared taps, formulae and casks
└── home/
    ├── default.nix            # stateVersion and the imports of every application
    ├── git/                   # One directory per application, each with its own default.nix
    ├── zsh/
    └── ...                    # kitty, neovim, tmux, starship, fish, nushell and others
```

Module conventions:

- One directory per application, with its own `default.nix`. Nix glue and the
  application's configuration files live together instead of mirroring the
  layout of `$HOME`.
- Platform differences are gated inside the shared module with
  `lib.mkIf pkgs.stdenv.isDarwin` or `pkgs.stdenv.isLinux`, never duplicated
  per configuration.

## Contributing

Issues and pull requests are accepted on GitHub. A change follows the module
conventions above.

## License

Released under the MIT License. See [LICENSE](LICENSE).
