_: {
  programs.wezterm = {
    enable = true;
    # Embedded verbatim (no re-serialization) -- the config is a full Lua
    # script, not just a settings table.
    extraConfig = builtins.readFile ./wezterm.lua;
  };
}
