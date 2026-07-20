{ pkgs, lib, ... }:
{
  # Electron/Chromium Ozone-Wayland flags, read by VS Code at every
  # startup from these exact paths -- Linux-only. Unlike a dormant config
  # entry, applying "--ozone-platform=wayland" on macOS could actually
  # break startup rather than just being ignored, so these are gated to
  # the Linux host only rather than deployed unconditionally.
  xdg.configFile = lib.mkIf pkgs.stdenv.isLinux {
    "code-flags.conf".source = ./code-flags.conf;
    "code-insiders-flags.conf".source = ./code-insiders-flags.conf;
  };
}
