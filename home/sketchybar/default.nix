{
  config,
  dotfilesRoot,
  pkgs,
  lib,
  ...
}:
{
  # Not using programs.sketchybar.config/service: helpers/menus contains a
  # C source file built via `make` into helpers/menus/bin/menus (gitignored,
  # a real compiled binary was already present locally), so this needs to
  # stay a writable, live checkout rather than a read-only store copy --
  # same treatment as cpp-tools/doom. Service lifecycle is left alone too,
  # for the same reason as skhd (avoid a second, conflicting launchd agent).
  # macOS-only, so gated behind lib.mkIf pkgs.stdenv.isDarwin.
  xdg.configFile."sketchybar" = lib.mkIf pkgs.stdenv.isDarwin {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/sketchybar/sketchybar";
  };
}
