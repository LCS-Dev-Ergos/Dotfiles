{ lib, pkgs, ... }:
{
  # Homebrew is the macOS package manager here; Linux hosts have none.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    home.packages = [ (pkgs.callPackage ./package.nix { }) ];
  };
}
