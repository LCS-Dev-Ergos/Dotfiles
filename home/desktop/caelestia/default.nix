{ lib, pkgs, ... }:
let
  sessionTarget = "wayland-session@hyprland.desktop.target";
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    # Caelestia 2.5.0 + CLI 1.1.3, with native quickshell-git and Qt >= 6.9.
    # Do not import upstream's HM module: it installs a Nix graphical runtime.
    xdg.configFile."caelestia/shell.json".source = ./shell.json;
    systemd.user.services.caelestia = {
      Unit = {
        Description = "Native Caelestia shell for Hyprland";
        After = [ sessionTarget ];
        PartOf = [ sessionTarget ];
        Requisite = [ sessionTarget ];
        ConditionEnvironment = "XDG_CURRENT_DESKTOP=Hyprland";
      };
      Service = {
        # Foreground process; do not detach with -d or restart via the CLI.
        ExecStart = "/usr/bin/qs -c caelestia";
        Environment = [ "QT_QPA_PLATFORM=wayland" ];
        Restart = "on-failure";
        RestartSec = 3;
        TimeoutStopSec = 5;
        Slice = "session.slice";
      };
      Install.WantedBy = [ sessionTarget ];
    };
  };
}
