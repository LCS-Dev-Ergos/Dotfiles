{ ... }:
{
  # KDL has no Nix parser (unlike btop/starship's TOML-adjacent formats),
  # so there's no safe way to route this through programs.zellij.settings
  # without hand-transcribing 400+ lines of nested keybinding blocks.
  # Linking the raw file avoids that risk entirely.
  programs.zellij.enable = true;

  xdg.configFile."zellij/config.kdl".source = ./config.kdl;
}
