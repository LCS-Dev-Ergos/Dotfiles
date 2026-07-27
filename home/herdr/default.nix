{ herdr, ... }:
{
  # herdr isn't packaged in nixpkgs; the `herdr` argument is upstream's own
  # flake build, resolved per-system in flake.nix's homeArgs and threaded
  # through the same way externalSources is.
  home.packages = [ herdr ];

  # Deployed straight from the store, like atuin's config.toml: edit this
  # file and switch generations rather than mutating state at runtime.
  # `herdr server reload-config` picks up the change without a restart.
  xdg.configFile."herdr/config.toml".source = ./config.toml;
}
