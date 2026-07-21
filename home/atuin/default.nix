_: {
  programs.atuin = {
    enable = true;
  };

  # Atuin's startup, shell initialization, and ordinary read paths leave this
  # file unchanged. Deploy the reviewed TOML directly from the store so a Nix
  # generation owns configuration changes and rollback. `atuin config set` is
  # intentionally not the durable update path; edit this source and switch.
  xdg.configFile."atuin/config.toml".source = ./config.toml;

  # config.toml's [theme] name = "tokyonight" references this file; atuin
  # doesn't have a dedicated Home Manager option for it, so it's placed
  # directly at its expected path.
  xdg.configFile."atuin/themes/tokyonight.toml".source = ./themes/tokyonight.toml;
}
