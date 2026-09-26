_: {
  # macOS-only applications and services; selected by Darwin host entrypoints.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.hostPlatform.isDarwin`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./desktop/aerospace
    ./desktop/borders
    ./desktop/sketchybar
    ./desktop/skhd
    ./desktop/yabai
  ];
}
