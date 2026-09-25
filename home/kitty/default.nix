_: {
  # Kitty never writes to its configuration, so both platforms use the
  # standard immutable recursive deployment; edits take effect after a switch
  # and a config reload (ctrl+shift+f5).
  xdg.configFile."kitty" = {
    source = ./kitty;
    recursive = true;
  };
}
