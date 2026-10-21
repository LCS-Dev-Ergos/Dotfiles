{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Import this module instead of linux/hyprland after installing native HyDE.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    assertions = [
      {
        assertion = !(config.xdg.configFile ? "hypr/legion.lua");
        message = "Select either the standalone Hyprland module or the HyDE overlay.";
      }
    ];
    xdg.configFile = {
      "hypr/hyprland.lua".source = ./hyprland.lua;
      "hypr/personal.lua".source = ./personal.lua;
      "hypr/personal-monitors.lua".source = ./monitors.lua;
      "hypr/personal-window-rules.lua".source = ./window-rules.lua;
      "hypr/hypridle.conf".source = ./hypridle.conf;
      "pypr/config.toml".source = ./pyprland.toml;
      "hyde/config.toml".source = ./config.toml;
    };
  };
}
