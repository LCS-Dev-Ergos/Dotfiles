_: {
  # Linux application settings shared by graphical sessions, including KDE.
  # The host selects desktop modules separately. HyDE is retired: neither
  # desktop/hypr nor desktop/hyprdots is imported by an active profile.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.hostPlatform.isLinux`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./editors/vscode
    ./file-managers/ueberzugpp
  ];
}
