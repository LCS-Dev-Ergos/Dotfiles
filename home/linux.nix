_: {
  # Linux-only configuration, mostly Hyprland/Wayland-specific; selected by
  # Linux host entrypoints. ueberzugpp is the exception -- a general Linux/X11
  # terminal-image tool, still confined to this layer because it has no
  # Darwin use.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.isLinux`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./hypr
    ./hyprdots
    ./ueberzugpp
    ./vscode
  ];
}
