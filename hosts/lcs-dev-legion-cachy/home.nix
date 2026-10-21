{
  config,
  dotfilesRoot,
  homeDirectory,
  username,
  ...
}:
{
  home = {
    inherit username homeDirectory;
  };

  # Standalone Home Manager has no system rebuild to drive activation. The
  # CLI comes from this flake's Home Manager input, so later switches use
  # the same version that built the generation.
  programs.home-manager.enable = true;

  # The CLI resolves this link before selecting the flake directory. Point
  # at the live checkout so it also finds flake.lock and relative imports;
  # a store copy of flake.nix alone would not be a usable configuration.
  xdg.configFile."home-manager/flake.nix".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/flake.nix";

  # Common applications also work in KDE. Native Hyprland services belong
  # to its UWSM session target. Caelestia is retired after physical evaluation.
  imports = [
    ../../home
    ../../home/linux.nix
    ../../home/desktop/linux/hyprland
  ];
}
