{
  pkgs,
  lib,
  ...
}:
{
  # Racket, with DrRacket, on Linux. On Darwin the Homebrew cask installs the
  # same release as an application bundle (see darwin/homebrew.nix).
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.racket ];
}
