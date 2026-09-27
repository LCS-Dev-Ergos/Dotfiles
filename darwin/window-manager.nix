{ config, lib, username, ... }:
{
  # pkgs.yabai becomes the signed fork release for nix-darwin and, through
  # useGlobalPkgs, for Home Manager (yabai's space.sh refers to it).
  nixpkgs.overlays = [
    (final: _prev: { yabai = final.callPackage ./yabai-package.nix { }; })
  ];

  # Both services read their configuration from the Home Manager managed
  # ~/.config/yabai/yabairc and ~/.config/skhd/skhdrc, so neither sets config
  # here.
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
    # Without a ProcessType, launchd throttles the agent's CPU and I/O, and
    # every command and event waits on it. yabai's own service file and the
    # skhd module use Interactive.
    ProcessType = "Interactive";
    StandardOutPath = "/tmp/yabai_${username}.out.log";
    StandardErrorPath = "/tmp/yabai_${username}.err.log";
  };
  launchd.user.agents.skhd = {
    # skhd runs every binding through $SHELL -c, and launchd would pass the
    # login zsh: its startup costs about 6 ms per key more than dash. The
    # bindings in skhdrc are POSIX sh.
    environment.SHELL = "/bin/dash";

    # launchd expands neither $HOME nor $USER in nix-darwin's systemPath, and
    # dash reads no startup file that would, so jq and sketchybar in the user
    # profile need the path spelled out.
    path = lib.mkForce [ ];
    environment.PATH =
      builtins.replaceStrings [ "$HOME" "$USER" ] [ "/Users/${username}" username ]
        config.environment.systemPath;

    serviceConfig = {
      StandardOutPath = "/tmp/skhd_${username}.out.log";
      StandardErrorPath = "/tmp/skhd_${username}.err.log";
    };
  };
}
