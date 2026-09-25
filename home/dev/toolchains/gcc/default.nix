{ pkgs, lib, ... }:
let
  inherit (import ../cc-toolchain.nix pkgs) gcc;
in
{
  # System-wide GCC, next to ../llvm, for whatever specifically wants GNU's
  # g++ (bits/stdc++.h, PBDS, Competitive Programming toolchains) rather than
  # Clang. Nix is the source of truth for it, at the release
  # ../cc-toolchain.nix selects; it supersedes Homebrew's copy, which stays
  # installed only because other formulae depend on it (see
  # darwin/homebrew.nix).
  #
  # On Darwin the `gcc` and `g++` names on PATH are the host drivers from
  # ../llvm/package.nix, which run this same compiler, from the same file,
  # against the host SDK and Apple's linker, together with gcov and gcc-ar.
  # Every program of this wrapper is shadowed there, so on Darwin it adds only
  # its manual pages. On Linux this wrapper is the compiler itself.
  #
  # setPrio 15: gcc and clang both ship generic cc/c++ symlinks (both at the
  # cc-wrapper default priority 10), which collide in the merged profile.
  # lib.lowPrio is actually a no-op here since it also resolves to 10 --
  # needs a number strictly higher than clang's to lose the tie.
  home.packages = [
    (lib.setPrio 15 gcc)
  ];
}
