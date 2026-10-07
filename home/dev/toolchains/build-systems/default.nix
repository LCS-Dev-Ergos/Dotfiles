{ pkgs, ... }:
{
  # Build-system generators, shared by every compiled language. Libraries that
  # projects find through CMake stay in Homebrew: CMake searches /opt/homebrew
  # by default, but not the Nix profile.
  home.packages = [
    pkgs.cmake
    pkgs.ninja
  ];
}
