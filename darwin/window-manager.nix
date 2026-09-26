{ username, ... }:
{
  # pkgs.yabai becomes the signed fork release for nix-darwin and, through
  # useGlobalPkgs, for Home Manager (skhd's focus_space.sh refers to it).
  nixpkgs.overlays = [
    (final: _prev: { yabai = final.callPackage ./yabai-package.nix { }; })
  ];

  # Both services read their configuration from the Home Manager managed
  # ~/.config/yabai/yabairc and ~/.config/skhd/skhdrc, so neither sets config
  # here. launchd gives both agents the login shell, which the zsh syntax in
  # skhdrc relies on.
  services.yabai = {
    enable = true;
    # Installs a boot-time `yabai --load-sa` daemon and writes
    # /etc/sudoers.d/yabai pinned to the SHA-256 of this exact binary, which
    # the `sudo yabai --load-sa` lines in yabairc depend on.
    enableScriptingAddition = true;
  };

  services.skhd.enable = true;

  # Keep the log files the Homebrew launchd agents used to write.
  launchd.user.agents.yabai.serviceConfig = {
    StandardOutPath = "/tmp/yabai_${username}.out.log";
    StandardErrorPath = "/tmp/yabai_${username}.err.log";
  };
  launchd.user.agents.skhd.serviceConfig = {
    StandardOutPath = "/tmp/skhd_${username}.out.log";
    StandardErrorPath = "/tmp/skhd_${username}.err.log";
  };
}
