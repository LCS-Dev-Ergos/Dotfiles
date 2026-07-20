{ ... }:
{
  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  home.stateVersion = "26.05";

  imports = [
    ./atuin
    ./bat
    ./btop
    ./fish
    ./kitty
    ./lazygit
    ./neovim
    ./nushell
    ./starship
    ./tmux
    ./zellij
  ];
}
