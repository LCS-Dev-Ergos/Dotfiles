{ config, dotfilesRoot, ... }:
{
  # LazyVim writes lazy-lock.json back into ~/.config/nvim whenever plugins
  # are updated. A plain `.source` copy would land in the read-only Nix
  # store and break that write. mkOutOfStoreSymlink instead links
  # ~/.config/nvim directly to the real file on disk, so it stays fully
  # writable while still being declared and tracked here.
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/nvim/.config/nvim";
}
