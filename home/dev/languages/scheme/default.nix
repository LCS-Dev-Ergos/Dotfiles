{
  pkgs,
  lib,
  ...
}:
{
  # MIT Scheme on Linux. nixpkgs does not build it for Darwin, where the
  # Homebrew formula provides it (see darwin/homebrew.nix).
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.mitscheme ];
}
