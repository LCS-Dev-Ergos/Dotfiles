{ config, dotfilesRoot, ... }:
{
  # custom.el is auto-rewritten by Emacs's Customize system at runtime
  # ("custom-set-variables was added by Custom"), so the whole directory
  # is kept live and writable via mkOutOfStoreSymlink rather than a
  # frozen store copy, same treatment as neovim's LazyVim tree.
  xdg.configFile."doom".source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/doom/doom";
}
