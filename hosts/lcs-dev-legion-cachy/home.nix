{ homeDirectory, username, ... }:
{
  home = {
    inherit username homeDirectory;
  };

  # Standalone Home Manager has no system rebuild to drive activation. The
  # CLI comes from this flake's Home Manager input, so later switches use
  # the same version that built the generation.
  programs.home-manager.enable = true;

  # Common applications also work in KDE. Native Hyprland services belong
  # to its UWSM session target. Caelestia is retired after physical evaluation.
  imports = [
    ../../home
    ../../home/linux.nix
    ../../home/desktop/hyprland
  ];
}
