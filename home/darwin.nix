_: {
  # macOS-only applications and services; selected by Darwin host entrypoints.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.isDarwin`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./aerospace
    ./borders
    ./sketchybar
    ./skhd
    ./yabai
  ];
}
