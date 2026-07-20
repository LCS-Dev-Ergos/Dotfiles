{ config, ... }:
{
  programs.fish = {
    enable = true;
    interactiveShellInit = builtins.readFile ./config.fish;
  };

  # rustup's own fish hook (sources ~/.cargo/env.fish); conf.d/*.fish files
  # are auto-sourced by fish on startup, so this just needs to land there.
  xdg.configFile."fish/conf.d/rustup.fish".source = ./rustup.fish;

  # fish_variables holds fish's own universal-variable state (color theme,
  # etc.) that fish itself rewrites via `set -U`. Kept writable via
  # mkOutOfStoreSymlink, seeded with the existing values, rather than
  # folded into the read-only Nix store.
  xdg.configFile."fish/fish_variables".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/fish/fish_variables";

  # completions/docker.fish, kubectl.fish, orbctl.fish were symlinks
  # OrbStack itself installed, pointing into /Applications/OrbStack.app/.
  # Not portable dotfiles content (and wrong on the Linux host), so they
  # were dropped rather than migrated; OrbStack will recreate them.
}
