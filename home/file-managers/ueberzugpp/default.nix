{
  lib,
  pkgs,
  nativeGraphics ? false,
  ...
}:
{
  # Primarily a Linux/X11 terminal-image tool, with no role on macOS.
  # It has no dedicated Home Manager module, so Linux installs the package and
  # links its small static JSON directly; Darwin gets neither option nor package.
  home.packages = lib.optionals (pkgs.stdenv.hostPlatform.isLinux && !nativeGraphics) [
    pkgs.ueberzugpp
  ];

  xdg.configFile."ueberzugpp/config.json" = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    source = ./config.json;
  };
}
