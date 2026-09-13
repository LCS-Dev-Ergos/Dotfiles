{ pkgs, lib, ... }:
{
  # System-wide GCC, next to home/llvm, for whatever specifically wants GNU's
  # g++ (bits/stdc++.h, PBDS, Competitive Programming toolchains) rather than
  # Clang. Nix is the source of truth for it: gcc16 is prebuilt for this
  # platform now, so it supersedes both the earlier gcc15 pin and Homebrew's
  # copy, which stays installed only because other formulae depend on it (see
  # darwin/homebrew.nix).
  #
  # On Darwin the `gcc` and `g++` names on PATH are the host drivers from
  # home/llvm/package.nix, which run this same compiler against the host SDK
  # and Apple's linker, together with gcov and gcc-ar; keep its gcc16 in step
  # with the one here. On Linux this wrapper is the compiler itself.
  #
  # setPrio 15: gcc and clang both ship generic cc/c++ symlinks (both at the
  # cc-wrapper default priority 10), which collide in the merged profile.
  # lib.lowPrio is actually a no-op here since it also resolves to 10 --
  # needs a number strictly higher than clang's to lose the tie.
  home.packages = [
    (lib.setPrio 15 pkgs.gcc16)
  ];
}
