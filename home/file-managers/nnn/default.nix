{ pkgs, ... }:
{
  # No rc/config file -- nnn is configured via NNN_OPTS/NNN_PLUG env vars,
  # which still live in the not-yet-migrated zsh config. This is just the
  # vendored nnn-plugins collection with local security fixes.
  home.packages = [
    pkgs.nnn
    pkgs.python3
  ];

  xdg.configFile."nnn/plugins" = {
    source = ./plugins;
    recursive = true;
  };
}
