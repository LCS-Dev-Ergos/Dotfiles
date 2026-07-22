{ pkgs, ... }:
let
  cppTools = pkgs.callPackage ./package.nix { };
in
{
  # Package the stable runtime while keeping the repository as its development
  # source. The compatibility path lets the custom Zsh lazy loader source the
  # same immutable modules as the standalone command.
  home.packages = [ cppTools ];
  xdg.configFile."cpp-tools".source = "${cppTools}/share/cpp-tools";
}
