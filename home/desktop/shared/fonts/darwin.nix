{ lib, pkgs, ... }:
let
  fonts = import ./packages.nix { inherit pkgs; };
in
{
  # System installation makes open fonts available to macOS GUI applications.
  fonts.packages = fonts.darwin;
  homebrew.casks = fonts.homebrew;
  # Symbola remains the sole reviewed exception; Apple SF fonts stay casks.
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "symbola";
}
