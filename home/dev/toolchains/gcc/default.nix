{
  pkgs,
  lib,
  ...
}:
let
  inherit (import ../cc-toolchain.nix pkgs) gcc;
in
{
  # GCC for whatever specifically wants GNU's g++ (bits/stdc++.h, PBDS,
  # Competitive Programming toolchains) rather than Clang. Nix is the source
  # of truth for it, at the release ../cc-toolchain.nix selects; it supersedes
  # Homebrew's copy, which stays installed only because other formulae depend
  # on it (see darwin/homebrew.nix).
  home.packages =
    # On Darwin `gcc` and `g++` are the host drivers from ../llvm/package.nix,
    # which run this same compiler against the host SDK and Apple's linker.
    # Every program of the nixpkgs wrapper would be shadowed by them, so only
    # the compiler's manual pages are installed.
    lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ gcc.cc.man ]
    # On Linux this wrapper is the compiler itself. setPrio 15: gcc and clang
    # both ship generic cc/c++ symlinks (both at the cc-wrapper default
    # priority 10), which collide in the merged profile. lib.lowPrio is a no-op
    # here since it also resolves to 10 -- a number strictly higher than
    # clang's is needed to lose the tie.
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ (lib.setPrio 15 gcc) ];
}
