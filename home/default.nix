{ ... }:
{
  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  home.stateVersion = "26.05";

  # fish's own module sets this to true (mkDefault) since it uses man
  # pages to build completions, but programs.man.package defaults to
  # null on Darwin (stateVersion >= 26.05) since macOS's own /usr/bin/man
  # already works without Nix managing it -- generateCaches has no
  # effect without a package, which is exactly the warning this avoids.
  programs.man.generateCaches = false;

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
    ./hyprdots
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
    ./zsh
  ];
}
