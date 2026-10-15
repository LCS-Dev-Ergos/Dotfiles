{
  pkgs,
  lib,
  ...
}:
{
  # Free Pascal on Linux. On Darwin fpcupdeluxe owns FPC together with the
  # Lazarus IDE in ~/.fpc-deluxe; nixpkgs has no Lazarus for Darwin, so
  # replacing it would lose the IDE.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.fpc ];
}
