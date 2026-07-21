{ config, dotfilesRoot, ... }:
{
  programs.atuin = {
    enable = true;
  };

  # `atuin config set` and Atuin's shell-initialization path both write
  # config.toml (the latter can recreate stock defaults repeatedly, not only on
  # first run). Keep the existing TOML authoritative, live, and writable; this
  # also avoids risky transcription into a Nix attrset. A generated
  # programs.atuin.settings file would be read-only, and force-overwriting it on
  # activation would discard legitimate runtime edits instead of managing them.
  xdg.configFile."atuin/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/atuin/config.toml";

  # config.toml's [theme] name = "tokyonight" references this file; atuin
  # doesn't have a dedicated Home Manager option for it, so it's placed
  # directly at its expected path.
  xdg.configFile."atuin/themes/tokyonight.toml".source = ./themes/tokyonight.toml;
}
