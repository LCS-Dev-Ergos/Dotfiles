{ homeDirectory, username, ... }:
{
  home = {
    inherit username homeDirectory;
  };

  # Common applications also work in KDE. Native Hyprland services belong
  # to its UWSM session target. Caelestia is retired after physical evaluation.
  imports = [
    ../../home
    ../../home/linux.nix
    ../../home/desktop/hyprland
  ];
}
