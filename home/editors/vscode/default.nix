{ pkgs, lib, ... }:
{
  # Manual tools, never run by a switch. vscode-host-settings rewrites the
  # host-bound values of the user's settings.json (see host-settings/README.md);
  # it is installed on every host because the same settings file is used on all
  # of them. vscode-sync shares Stable's extensions and user files with
  # Insiders (see sync/README.md).
  home.packages = [
    (pkgs.callPackage ./host-settings/package.nix { })
    (pkgs.callPackage ./sync/package.nix { })
  ];

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
