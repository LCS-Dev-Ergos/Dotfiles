{ pkgs, ... }:
{
  # Interpreters come from pyenv (home/zsh/config/lib/80-languages.zsh) and
  # project environments from Conda; these are the project and lint tools that
  # work across all of them.
  home.packages = [ pkgs.ruff ];

  # uv resolves projects, tools and scripts against those interpreters only:
  # it neither uses nor downloads Python builds of its own, which would add a
  # third, unmanaged copy next to pyenv and Conda.
  programs.uv = {
    enable = true;
    settings = {
      python-preference = "only-system";
      python-downloads = "never";
    };
  };
  # Replaces the hand-written uv.toml that predates this module.
  xdg.configFile."uv/uv.toml".force = true;
}
