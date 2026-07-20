{ pkgs, lib, ... }:
{
  # yabai is a macOS-only tiling window manager with no Home Manager
  # module (neither programs.yabai nor services.yabai exist), so this is
  # gated to Darwin and linked raw -- yabairc is yabai's own shell-based
  # config DSL, no safe Nix parser regardless.
  xdg.configFile."yabai/yabairc" = lib.mkIf pkgs.stdenv.isDarwin {
    source = ./yabairc;
    executable = true;
  };
}
