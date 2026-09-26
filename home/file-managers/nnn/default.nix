{ pkgs, ... }:
{
  # No rc/config file -- nnn is configured via NNN_OPTS/NNN_PLUG env vars,
  # which still live in the not-yet-migrated zsh config. This is just the
  # stock official nnn-plugins collection (unmodified, no personalization
  # found), vendored as static files rather than a live git checkout.
  home.packages = [ pkgs.nnn ];

  xdg.configFile."nnn/plugins" = {
    source = ./plugins;
    recursive = true;
  };
}
