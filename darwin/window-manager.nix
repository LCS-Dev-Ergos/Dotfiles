{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  # TCC keys the Accessibility and Screen Recording grants of a bare binary to
  # its path, and checks the signature's requirement on top. Every release has
  # a new store path, so each one asked for both grants again, and until yabai
  # restarted after the Screen Recording grant, snapshot crossfades and window
  # animations were silently off. launchd therefore runs a copy at a fixed,
  # root-owned path: the copy keeps the embedded signature, and every signed
  # release still meets the requirement stored with the grants.
  yabaiDaemon = "/opt/yabai/bin/yabai";
in
{
  # pkgs.yabai becomes the signed fork release for nix-darwin and, through
  # useGlobalPkgs, for Home Manager (yabai's space.sh refers to it).
  nixpkgs.overlays = [
    (final: _prev: { yabai = final.callPackage ./yabai-package.nix { }; })
  ];

  # extraActivation runs before launchd reloads the agent. The new binary
  # replaces the old one by rename: the running daemon keeps the file it was
  # started from, whose pages the kernel checks against its signature.
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    if ! cmp -s ${pkgs.yabai}/bin/yabai ${yabaiDaemon}; then
      echo "installing yabai at ${yabaiDaemon}..." >&2
      install -d -o root -g wheel -m 755 /opt/yabai /opt/yabai/bin
      install -o root -g wheel -m 755 ${pkgs.yabai}/bin/yabai ${yabaiDaemon}.new
      mv -f ${yabaiDaemon}.new ${yabaiDaemon}
    fi
  '';

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
    # The fixed copy above. The module's PATH still names the store path, so
    # the agent's plist, and with it yabai, changes with every release;
    # `sudo yabai --load-sa` in yabairc resolves to that store path, which
    # /etc/sudoers.d/yabai pins.
    ProgramArguments = lib.mkForce [ yabaiDaemon ];

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
