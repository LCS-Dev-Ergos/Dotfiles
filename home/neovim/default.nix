{ config, ... }:
let
  # mkOutOfStoreSymlink needs a real, non-store-copied absolute path.
  # Flakes copy their own source tree into /nix/store as part of
  # evaluation, so a relative literal like `./nvim` here would resolve
  # inside that read-only copy instead of this repo checkout, silently
  # breaking the "stays writable" guarantee this symlink exists for.
  # Derived from home.homeDirectory (set per-host) rather than hardcoded,
  # since this module is shared across the macOS and Linux hosts.
  nvimSource = "${config.home.homeDirectory}/Dotfiles/home/neovim/nvim";
in
{
  # LazyVim writes lazy-lock.json back into ~/.config/nvim whenever plugins
  # are updated. A plain `.source` copy would land in the read-only Nix
  # store and break that write. mkOutOfStoreSymlink instead links
  # ~/.config/nvim directly to the real file on disk, so it stays fully
  # writable while still being declared and tracked here.
  xdg.configFile."nvim".source = config.lib.file.mkOutOfStoreSymlink nvimSource;
}
