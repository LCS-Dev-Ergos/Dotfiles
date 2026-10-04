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
  #
  # cppcheck is the static analyzer behind the C++ scope's analyze step. The
  # cpp-tools health command is called cpphealth so it never shadows it.
  home.packages = [
    cppTools
    pkgs.cppcheck
  ];
  xdg.configFile = {
    "cpp-tools".source = "${cppTools}/share/cpp-tools";
    # YAML, no builtins.fromYAML in Nix and no dedicated Home Manager module
    # for clang-format, so linked raw.
    "clang-format/.clang-format".source = ./.clang-format;
  };
}
