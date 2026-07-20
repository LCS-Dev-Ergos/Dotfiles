{ ... }:
{
  # config.yml has always been empty (0 bytes) -- lazygit already runs on
  # its own built-in defaults, so there's no settings to carry over. The
  # empty file is kept for history/consistency but isn't wired in.
  programs.lazygit.enable = true;
}
