_: {
  # macOS-only applications and services; selected by Darwin host entrypoints.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.hostPlatform.isDarwin`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./cli/brew-stats
    ./desktop/macos/aerospace
    ./desktop/macos/borders
    ./desktop/macos/sketchybar
    ./desktop/macos/skhd
    ./desktop/macos/yabai
  ];
}
