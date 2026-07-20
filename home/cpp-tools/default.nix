{ config, ... }:
{
  # A personal, actively-developed toolchain project (cpptools + modules/
  # + tests), not passive config -- kept as a live, writable checkout via
  # mkOutOfStoreSymlink rather than a frozen read-only store copy, same
  # treatment as neovim's LazyVim tree.
  xdg.configFile."cpp-tools" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/cpp-tools/cpp-tools";
  };
}
