{ pkgs, ... }:
let
  cppTools = pkgs.callPackage ./cpp-tools.nix { };
in
{
  # The compilers themselves live in ../../toolchains; this is the C/C++
  # workflow on top of them.
  #
  # cpp-tools: package the stable runtime while keeping the repository as its
  # development source. The compatibility path lets the custom Zsh lazy loader
  # source the same immutable modules as the standalone command.
  home.packages = [ cppTools ];
  xdg.configFile = {
    "cpp-tools".source = "${cppTools}/share/cpp-tools";
    # YAML, no builtins.fromYAML in Nix and no dedicated Home Manager module
    # for clang-format, so linked raw.
    "clang-format/.clang-format".source = ./.clang-format;
  };
}
