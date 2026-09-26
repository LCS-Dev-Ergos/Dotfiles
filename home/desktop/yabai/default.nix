{ pkgs, lib, ... }:
{
  # yabai itself runs as nix-darwin's services.yabai (darwin/window-manager.nix),
  # which reads this file from its default location. Home Manager has no yabai
  # module, and yabairc is yabai's own shell-based config DSL with no safe Nix
  # parser, so it is gated to Darwin and linked raw.
  xdg.configFile = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    "yabai/yabairc" = {
      source = ./yabairc;
      executable = true;
    };

    # Space focus and window moves with a short fade-in, called by skhd and
    # SketchyBar. pkgs.yabai is the signed fork release from
    # darwin/window-manager.nix; both store paths are substituted via
    # lib.getExe.
    "yabai/space.sh" = {
      source = pkgs.replaceVars ./space.sh {
        jq = lib.getExe pkgs.jq;
        yabai = lib.getExe pkgs.yabai;
      };
      executable = true;
    };
  };
}
