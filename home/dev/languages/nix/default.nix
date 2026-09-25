{ pkgs, ... }:
{
  # Language server, formatter and linter for this repository's own language.
  home.packages = [
    pkgs.nixd
    pkgs.nixfmt
    pkgs.statix
  ];
}
