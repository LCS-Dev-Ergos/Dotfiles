{ homeDirectory, username, ... }:
{
  home = {
    inherit username homeDirectory;
  };

  # Common applications also work in KDE. Only these two desktop modules
  # select Hyprland; their services belong to its UWSM session target.
  imports = [
    ../../home
    ../../home/linux.nix
    ../../home/desktop/hyprland
    ../../home/desktop/caelestia
  ];
}
