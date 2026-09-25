{ pkgs, ... }:
{
  # Interpreters come from pyenv (home/zsh/config/lib/80-languages.zsh); these
  # are the project and lint tools that work across all of them.
  home.packages = [
    pkgs.ruff
    pkgs.uv
  ];
}
