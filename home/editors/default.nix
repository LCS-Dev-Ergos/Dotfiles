_: {
  # Text editors shared by every host. The VS Code module gates its
  # Linux-only startup flags internally.
  imports = [
    ./doom
    ./markdown
    ./neovim
    ./vscode
    ./zed
  ];
}
