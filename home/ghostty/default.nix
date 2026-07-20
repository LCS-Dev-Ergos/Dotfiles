{ pkgs, lib, ... }:
{
  # Not using programs.ghostty.settings: values are unquoted bare text
  # (e.g. `font-family = CaskaydiaCove Nerd Font`), which isn't valid
  # TOML, and macos-titlebar-style is set twice (ghostty takes the last
  # occurrence) -- duplicate-key semantics an attrset can't represent
  # anyway. Linked raw for exact fidelity.
  # package = null only on Darwin: nixpkgs' ghostty isn't buildable on
  # aarch64-darwin; ghostty itself is Homebrew-installed there, only its
  # config is Nix-managed. Forcing this unconditionally broke the Linux
  # host instead, where programs.ghostty.systemd.enable defaults to true
  # and asserts a real package must be set.
  programs.ghostty = {
    enable = true;
    package = lib.mkIf pkgs.stdenv.isDarwin null;
  };

  xdg.configFile."ghostty/config".source = ./config;

  xdg.configFile."ghostty/shaders" = {
    source = ./shaders;
    recursive = true;
  };
}
