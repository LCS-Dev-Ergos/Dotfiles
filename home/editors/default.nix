_: {
  # Text editors shared by every host. VS Code is Linux-only and is selected
  # by home/linux.nix instead.
  imports = [
    ./doom
    ./neovim
    ./zed
  ];
}
