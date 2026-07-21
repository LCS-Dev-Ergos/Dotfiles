_: {
  programs.fastfetch.enable = true;

  # config.jsonc is JSON-with-comments; Nix's builtins.fromJSON is strict
  # JSON and errors on comments, so this is linked raw rather than routed
  # through programs.fastfetch.settings.
  xdg.configFile = {
    "fastfetch/config.jsonc".source = ./config.jsonc;
    "fastfetch/pngs" = {
      source = ./pngs;
      recursive = true;
    };
    "fastfetch/scripts" = {
      source = ./scripts;
      recursive = true;
    };
  };
}
