{
  config,
  dotfilesRoot,
  pkgs,
  lib,
  ...
}:
{
  # Companion theming/wallpaper-color tooling for the Hyprland setup. The Linux
  # host remains unverified on real hardware, but inspection confirms wallbash,
  # palette, and wallpaper-color scripts generate/update state inside this
  # tree. A recursive store copy would therefore fail at runtime; preserve the
  # complete tree as one writable link until real-host testing can refine it.
  xdg.configFile."hyprdots" = lib.mkIf pkgs.stdenv.isLinux {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/hyprdots/hyprdots";
  };
}
