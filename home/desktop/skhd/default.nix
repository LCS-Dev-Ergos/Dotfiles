{ pkgs, lib, ... }:
{
  # skhd itself runs as nix-darwin's services.skhd (darwin/window-manager.nix),
  # which reads this file from its default location. skhd's own hotkey DSL
  # has no safe Nix parser, so the config stays a plain file. The space
  # bindings call ~/.config/yabai/space.sh from the yabai module.
  xdg.configFile."skhd/skhdrc" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    source = ./skhdrc;
  };
}
