# ZSH Dependencies

The dependency model has three levels:

- **required** supports the shell runtime, documentation generation, and the
  full verification suite;
- **recommended** enables the intended interactive experience;
- **optional** activates a specific command family and may be absent safely.

`home/zsh/packages/zsh-dependencies.tsv` is the single source of truth. The
`Brewfile` and Arch package list are generated views; do not edit them by hand.

Each row names the package per owner: `homebrew`, `arch`, and `nix`. The `nix`
column holds the Home Manager package name that supplies the command on a
flake-managed host, or `-` when another owner does (nix-darwin for zsh, pyenv
for python3, Homebrew or the distribution for the rest). `home/zsh/default.nix`
asserts that every name in that column is installed by some Home Manager
module, so a rename or a package changing owner fails the build instead of
leaving a stale install hint.

`zshdeps` picks the hint owner from where it runs: the `nix` column for a
configuration deployed from the Nix store, Homebrew on other macOS hosts, and
pacman or the AUR on Arch. `ZSH_DEPENDENCY_OWNER=nix|homebrew|arch` overrides
the choice.

## Inspect the current machine

After loading the shell, run:

```zsh
zshdeps
zshdeps --required
zshdeps --all
```

The default report lists every dependency but fails only when a required tool
is missing. `--all` makes every missing feature dependency an error.

To validate that committed manifests still match the registry:

```zsh
zshdeps --required --check-manifests
```

After changing the TSV registry, regenerate both manifests with:

```zsh
zshdeps --sync-manifests
```

The deployed checker is store-backed and read-only. For this explicitly
mutating command it writes to `~/Dotfiles/home/zsh` by default; set
`ZSH_DOTFILES_ROOT` when the checkout lives elsewhere. Ordinary checks always
read the manifests from the active generation.

## macOS

The generated Brewfile is a standalone compatibility bootstrap for a macOS
machine that is not yet managed by this flake. The active nix-darwin host uses
`darwin/homebrew.nix` plus shared Home Manager packages instead; do not run the
standalone Brewfile there unless duplicate Homebrew ownership is intentional.

On an unmanaged macOS host, Homebrew Bundle installs the declared formulae:

```zsh
brew bundle --file ~/Dotfiles/home/zsh/Brewfile
```

The Brewfile captures the desired package set, not exact formula versions.
Homebrew decides the current versions available from configured repositories.

On the flake-managed host, `home/zsh/default.nix` owns the documentation
toolchain: gawk from nixpkgs and shdoc, which nixpkgs does not package, built
by `home/zsh/shdoc.nix` from the same checksum-pinned v1.4 release.

`shdoc` has no Homebrew formula. On an unmanaged host, install the pinned
release with the repository helper:

```zsh
~/.config/zsh/scripts/install-shdoc.zsh
~/.config/zsh/scripts/install-shdoc.zsh --check
```

The helper stores the upstream AWK program below `~/.local/share`, installs a
portable wrapper below `~/.local/bin`, and refuses a checksum mismatch.

## Arch Linux

Install packages from official repositories with:

```zsh
sudo pacman -S --needed - < ~/Dotfiles/home/zsh/packages/arch-zsh.txt
```

The registry marks packages outside the official repositories with an `aur:`
prefix. Install those explicitly with the trusted AUR workflow of your choice:

- `shdoc-git` provides `shdoc`;
- `fabric-ai-bin` provides `fabric-ai`.

AUR packages are intentionally excluded from `arch-zsh.txt`: they are
user-produced build recipes and require a separate trust decision.

## CI Policy

CI installs only the required validation toolchain. It does not install every
interactive or feature-specific package. This keeps validation fast while the
manifest consistency check ensures the complete declared package sets remain
reproducible.
