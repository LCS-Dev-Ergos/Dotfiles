{
  lib,
  nativeGraphics ? false,
  ...
}:
{
  programs.wezterm = {
    enable = !nativeGraphics;
    # Embedded verbatim (no re-serialization) -- the config is a full Lua
    # script, not just a settings table.
    extraConfig = builtins.readFile ./wezterm.lua;
  };
  # Home Manager's WezTerm package option is not nullable. Deploy the same
  # raw config directly when pacman owns the graphical runtime.
  xdg.configFile."wezterm/wezterm.lua" = lib.mkIf nativeGraphics {
    source = ./wezterm.lua;
  };
}
