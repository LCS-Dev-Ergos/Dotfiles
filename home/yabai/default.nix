{ pkgs, lib, ... }:
{
  # yabai itself runs as nix-darwin's services.yabai (darwin/window-manager.nix),
  # which reads this file from its default location. Home Manager has no yabai
  # module, and yabairc is yabai's own shell-based config DSL with no safe Nix
  # parser, so it is gated to Darwin and linked raw.
  xdg.configFile."yabai/yabairc" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    source = ./yabairc;
    executable = true;
  };
}
