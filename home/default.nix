{ ... }:
{
  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  home.stateVersion = "26.05";

  imports = [
    ./atuin
    ./bat
    ./btop
    ./cava
    ./clang-format
    ./cpp-tools
    ./doom
    ./fastfetch
    ./fish
    ./kitty
    ./lazygit
    ./neofetch
    ./neovim
    ./nnn
    ./nushell
    ./oh-my-posh
    ./ranger
    ./starship
    ./tealdeer
    ./tmux
    ./yazi
    ./zellij
  ];
}
