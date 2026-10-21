{ lib, pkgs, ... }:
{
  # Fonts the shared terminal configurations rely on beyond what the
  # distribution ships. JuliaMono backs the Kitty and Ghostty code point maps
  # (scripts/updates/font-codepoint-maps.toml); darwin.nix installs the Darwin
  # inventory through nix-darwin. fontconfig must be enabled so
  # applications discover fonts in the Home Manager profile.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    fonts.fontconfig.enable = true;
    home.packages = (import ./packages.nix { inherit pkgs; }).linux;
  };
}
