{ pkgs, lib, ... }:
{
  # Not using services.skhd.enable: that would have Home Manager create
  # and manage its own launchd agent for skhd, which could conflict with
  # however skhd is already being started (Homebrew services or manual).
  # Only the config is Nix-managed here, matching yabai's treatment;
  # skhd's own hotkey DSL has no safe Nix parser regardless.
  xdg.configFile = lib.mkIf pkgs.stdenv.isDarwin {
    "skhd/skhdrc".source = ./skhdrc;
    "skhd/focus_space.sh" = {
      source = ./focus_space.sh;
      executable = true;
    };
  };
}
