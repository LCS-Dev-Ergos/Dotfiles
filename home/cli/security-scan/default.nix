{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  # The signatures are per user and re-downloadable, but a scan needs them,
  # so they live with application data rather than in a cache.
  database = "${config.xdg.dataHome}/clamav";
  logs = "${config.xdg.stateHome}/clamav";
  # freshclam with this configuration: the scheduled update and the shell
  # run the same command, and security-scan reads the same folder.
  freshclam = pkgs.writeShellScriptBin "freshclam" ''
    mkdir -p ${lib.escapeShellArg database}
    exec ${pkgs.clamav}/bin/freshclam \
      --config-file=${lib.escapeShellArg "${config.xdg.configHome}/clamav/freshclam.conf"} "$@"
  '';
  # The scheduled update logs only errors, under the state directory.
  update = pkgs.writeShellScript "freshclam-update" ''
    mkdir -p ${lib.escapeShellArg logs}
    exec ${freshclam}/bin/freshclam --quiet \
      >> ${lib.escapeShellArg "${logs}/freshclam.log"} 2>&1
  '';
in
{
  # Structural checks, YARA and ClamAV are all bundled; freshclam keeps
  # ClamAV's signatures current once a day.
  home.packages = [
    (pkgs.callPackage ./package.nix { })
    freshclam
  ];

  xdg.configFile."clamav/freshclam.conf".text = ''
    DatabaseDirectory ${database}
    DatabaseMirror database.clamav.net
  '';

  launchd.agents.freshclam = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ (toString update) ];
      RunAtLoad = true;
      StartCalendarInterval = [
        {
          Hour = 10;
          Minute = 30;
        }
      ];
      ProcessType = "Background";
      LowPriorityIO = true;
    };
  };

  systemd.user = lib.mkIf isLinux {
    services.freshclam = {
      Unit.Description = "Update ClamAV's signatures for security-scan";
      Service = {
        Type = "oneshot";
        ExecStart = toString update;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    timers.freshclam = {
      Unit.Description = "Update ClamAV's signatures daily";
      Timer = {
        OnStartupSec = "10min";
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
