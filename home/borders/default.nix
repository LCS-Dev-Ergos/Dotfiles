{ pkgs, lib, ... }:
{
  # Not using services.jankyborders: that would have Home Manager create
  # and manage its own launchd agent, which could conflict with however
  # borders is already being started. active_color is also set twice
  # (last wins), duplicate-key semantics an attrset can't represent.
  # macOS-only, gated behind lib.mkIf pkgs.stdenv.isDarwin.
  xdg.configFile."borders/bordersrc" = lib.mkIf pkgs.stdenv.isDarwin {
    source = ./bordersrc;
    executable = true;
  };
}
