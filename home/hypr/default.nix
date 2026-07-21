{
  config,
  dotfilesRoot,
  lib,
  pkgs,
  ...
}:
{
  # Hyprland is a Wayland compositor, Linux-only. This config was never
  # live on the Mac (nothing was Stow-symlinked here), and the Linux host
  # itself is still unverified -- no physical/remote access to test on.
  # Keep the exact original files rather than risk an unverified translation
  # through wayland.windowManager.hyprland's typed settings.
  #
  # This must also be writable: Hyprdots replaces themes/theme.conf and writes
  # colors.conf/Wall-Dcol.conf in this tree during theme changes. A recursive
  # store deployment would either reject those writes or replace managed links
  # with untracked runtime copies. The whole Linux-only tree therefore follows
  # the same out-of-store policy as Hyprdots itself.
  xdg.configFile."hypr" = lib.mkIf pkgs.stdenv.isLinux {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/hypr/hypr";
  };
}
