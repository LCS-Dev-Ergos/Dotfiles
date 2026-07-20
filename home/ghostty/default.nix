{ ... }:
{
  # Not using programs.ghostty.settings: values are unquoted bare text
  # (e.g. `font-family = CaskaydiaCove Nerd Font`), which isn't valid
  # TOML, and macos-titlebar-style is set twice (ghostty takes the last
  # occurrence) -- duplicate-key semantics an attrset can't represent
  # anyway. Linked raw for exact fidelity.
  # package = null: nixpkgs' ghostty isn't buildable on aarch64-darwin;
  # ghostty itself is Homebrew-installed here, only its config is
  # Nix-managed.
  programs.ghostty = {
    enable = true;
    package = null;
  };

  xdg.configFile."ghostty/config".source = ./config;

  xdg.configFile."ghostty/shaders" = {
    source = ./shaders;
    recursive = true;
  };
}
