# ZSH Dependencies

The dependency model has three levels:

- **required** supports the shell runtime, documentation generation, and the
  full verification suite;
- **recommended** enables the intended interactive experience;
- **optional** activates a specific command family and may be absent safely.

`home/zsh/packages/zsh-dependencies.tsv` is the single source of truth. The
`Brewfile` and Arch package list are generated views; do not edit them by hand.

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

## macOS

Homebrew Bundle installs the declared formulae:

```zsh
brew bundle --file ~/Dotfiles/home/zsh/Brewfile
```

The Brewfile captures the desired package set, not exact formula versions.
Homebrew decides the current versions available from configured repositories.

`shdoc` is not currently represented by a Homebrew formula in this manifest.
Install the checksum-pinned release with the repository helper:

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
