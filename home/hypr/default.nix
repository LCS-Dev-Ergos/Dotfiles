{ pkgs, lib, ... }:
{
  # Hyprland is a Wayland compositor, Linux-only. This config was never
  # live on the Mac (nothing was Stow-symlinked here), and the Linux host
  # itself is still unverified -- no physical/remote access to test on.
  # Preserved as a plain recursive copy rather than routed through
  # wayland.windowManager.hyprland's native settings options, since
  # correctness here can't be verified at all from this machine; safer to
  # keep the exact original files than risk an unverified transcription.
  xdg.configFile."hypr" = lib.mkIf pkgs.stdenv.isLinux {
    source = ./hypr;
    recursive = true;
  };
}
