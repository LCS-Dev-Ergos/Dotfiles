{ lib, pkgs, ... }:
{
  # Primarily a Linux/X11 terminal-image tool and previously inert on the Mac.
  # It has no dedicated Home Manager module, so Linux installs the package and
  # links its small static JSON directly; Darwin gets neither option nor package.
  home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.ueberzugpp ];

  xdg.configFile."ueberzugpp/config.json" = lib.mkIf pkgs.stdenv.isLinux {
    source = ./config.json;
  };
}
