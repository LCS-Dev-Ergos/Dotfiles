_: {
  # Everything that builds or checks code, in two layers:
  #  - toolchains/: compilers, linkers and debuggers shared by several
  #    languages, with their versions chosen once in cc-toolchain.nix;
  #  - languages/: per-language tools and configuration, one directory each.
  # Runtimes that a version manager owns (rustup, pyenv, opam, ...) are wired
  # into the shell by home/zsh/config/lib/80-languages.zsh, not installed here.
  imports = [
    ./toolchains
    ./languages
  ];
}
