{ ... }:
{
  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  home.stateVersion = "26.05";

  imports = [
    ./alacritty
    ./atuin
    ./bat
    ./btop
    ./cava
    ./clang-format
    ./cpp-tools
    ./doom
    ./fastfetch
    ./fish
    ./ghostty
    ./kitty
    ./lazygit
    ./lldb
    ./neofetch
    ./neovim
    ./nnn
    ./nushell
    ./oh-my-posh
    ./ranger
    ./skhd
    ./starship
    ./tealdeer
    ./tmux
    ./ueberzugpp
    ./vscode
    ./wezterm
    ./yabai
    ./yazi
    ./zed
    ./zellij
  ];
}
