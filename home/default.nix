{ ... }:
{
  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  home.stateVersion = "26.05";

  imports = [
    ./aerospace
    ./alacritty
    ./atuin
    ./bat
    ./borders
    ./btop
    ./cava
    ./clang-format
    ./cpp-tools
    ./doom
    ./fastfetch
    ./fish
    ./ghostty
    ./hypr
    ./kitty
    ./lazygit
    ./lldb
    ./neofetch
    ./neovim
    ./nnn
    ./nushell
    ./oh-my-posh
    ./ranger
    ./sketchybar
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
