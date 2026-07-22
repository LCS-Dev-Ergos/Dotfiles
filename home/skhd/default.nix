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
      # jq is a real Nix package, so its store path is substituted via
      # lib.getExe. yabai has no nixpkgs derivation at all (see
      # home/yabai/default.nix) and is Homebrew-only, so its path is the
      # fixed Apple Silicon Homebrew prefix instead of a store reference.
      source = pkgs.replaceVars ./focus_space.sh {
        jq = lib.getExe pkgs.jq;
        yabai = "/opt/homebrew/bin/yabai";
      };
      executable = true;
    };
  };
}
