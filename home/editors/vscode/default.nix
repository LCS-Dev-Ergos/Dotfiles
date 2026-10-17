{ pkgs, lib, ... }:
{
  # Manual tool, never run by a switch: it rewrites the host-bound values of the
  # user's settings.json (see host-settings/README.md). Installed on every host
  # because the same settings file is used on all of them.
  home.packages = [ (pkgs.callPackage ./host-settings/package.nix { }) ];

  # Electron/Chromium Ozone-Wayland flags, read by VS Code at every
  # startup from these exact paths -- Linux-only. Unlike a dormant config
  # entry, applying "--ozone-platform=wayland" on macOS could actually
  # break startup rather than just being ignored, so these are gated to
  # the Linux host only rather than deployed unconditionally.
  xdg.configFile = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    "code-flags.conf".source = ./code-flags.conf;
    "code-insiders-flags.conf".source = ./code-insiders-flags.conf;
  };
}
