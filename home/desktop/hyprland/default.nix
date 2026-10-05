{ lib, pkgs, ... }:
let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  sessionUnit = {
    After = [ sessionTarget ];
    PartOf = [ sessionTarget ];
    Requisite = [ sessionTarget ];
    ConditionEnvironment = "XDG_CURRENT_DESKTOP=Hyprland";
  };
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    # Native Hyprland 0.56 uses Lua. Do not enable HM's Hyprland module:
    # pacman owns the compositor and UWSM owns its systemd lifecycle.
    xdg.configFile = {
      "hypr/hyprland.lua".source = ./hyprland.lua;
      "hypr/legion.lua".source = ./legion.lua;
      "xdg-desktop-portal/hyprland-portals.conf".text = ''
        [preferred]
        default=hyprland;gtk
        org.freedesktop.impl.portal.FileChooser=kde
        org.freedesktop.impl.portal.Secret=kwallet
      '';
      # Keep Qt/NVIDIA settings out of HM sessionVariables: those would also
      # affect Plasma. UWSM reads this only for the Hyprland desktop entry.
      "uwsm/env-hyprland".text = ''
        export LIBVA_DRIVER_NAME=nvidia
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export QT_QPA_PLATFORM=wayland
        export QT_QPA_PLATFORMTHEME=kde
        export UWSM_WAIT_VARNAMES="''${UWSM_WAIT_VARNAMES:+$UWSM_WAIT_VARNAMES }HYPRLAND_INSTANCE_SIGNATURE"
      '';
    };

    systemd.user.services = {
      legion-polkit = {
        Unit = sessionUnit // {
          Description = "Native KDE polkit agent for Hyprland";
        };
        Service = {
          ExecStart = "/usr/lib/polkit-kde-authentication-agent-1";
          Restart = "on-failure";
          Slice = "session.slice";
        };
        Install.WantedBy = [ sessionTarget ];
      };
      legion-clipboard = {
        Unit = sessionUnit // {
          Description = "Hyprland clipboard history";
        };
        Service = {
          ExecStart = "/usr/bin/wl-paste --watch /usr/bin/cliphist store";
          Restart = "on-failure";
          Slice = "background.slice";
        };
        Install.WantedBy = [ sessionTarget ];
      };
    };
  };
}
