_: {
  # Linux application settings shared by graphical sessions, including KDE.
  # The host selects a desktop separately; linux/hyde is an optional alternative.
  # Each of these modules also gates its own options/packages internally with
  # `lib.mkIf pkgs.stdenv.hostPlatform.isLinux`, so a module stays correct on its own even
  # if it is ever imported from somewhere other than this file.
  imports = [
    ./dev/languages/fortran
    ./dev/languages/pascal
    ./dev/languages/racket
    ./dev/languages/scheme
    ./file-managers/ueberzugpp
  ];
}
