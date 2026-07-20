{ ... }:
{
  # config.jsonc is JSON-with-comments; Nix's builtins.fromJSON is strict
  # JSON and errors on comments, so this is linked raw rather than routed
  # through programs.fastfetch.settings.
  xdg.configFile."fastfetch/config.jsonc".source = ./config.jsonc;

  xdg.configFile."fastfetch/pngs" = {
    source = ./pngs;
    recursive = true;
  };

  xdg.configFile."fastfetch/scripts" = {
    source = ./scripts;
    recursive = true;
  };
}
