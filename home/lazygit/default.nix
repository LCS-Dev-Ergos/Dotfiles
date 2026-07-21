_: {
  # config.yml has always been empty (0 bytes), so LazyGit uses its built-in
  # defaults. The file remains in the repository for history/consistency but is
  # deliberately not wired into Home Manager as a fake source of configuration.
  programs.lazygit.enable = true;
}
