{ pkgs, lib, ... }:
{
  # skhd itself runs as nix-darwin's services.skhd (darwin/window-manager.nix),
  # which reads this file from its default location. skhd's own hotkey DSL
  # has no safe Nix parser, so the config stays a plain file.
  xdg.configFile = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    "skhd/skhdrc".source = ./skhdrc;
    "skhd/focus_space.sh" = {
      # Both store paths are substituted via lib.getExe. pkgs.yabai is the
      # signed fork release from darwin/window-manager.nix.
      source = pkgs.replaceVars ./focus_space.sh {
        jq = lib.getExe pkgs.jq;
        yabai = lib.getExe pkgs.yabai;
      };
      executable = true;
    };
  };
}
