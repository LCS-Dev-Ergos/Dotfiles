{ pkgs, lib, ... }:
{
  # System-wide GCC, next to home/llvm, for whatever specifically wants GNU's
  # g++ (bits/stdc++.h, PBDS, Competitive Programming toolchains) rather than
  # Clang. Pinned to gcc15, not gcc16: gcc16 has no prebuilt binary for this
  # platform yet and fails its own bootstrap from source here (stage1 error),
  # verified empirically.
  #
  # gcc15 fetches prebuilt and compiled/ran a bits/stdc++.h + PBDS C++23 smoke
  # test with zero env vars, same as clang. Homebrew's gcc stays installed and
  # declared on purpose (see darwin/homebrew.nix) -- other Homebrew formulae
  # still need it.
  #
  # setPrio 15: gcc and clang both ship generic cc/c++ symlinks (both at the
  # cc-wrapper default priority 10), which collide in the merged profile.
  # lib.lowPrio is actually a no-op here since it also resolves to 10 --
  # needs a number strictly higher than clang's to lose the tie. Clang keeps
  # winning cc/c++ (unchanged default); gcc's own gcc/g++ names never
  # collide with anything, so they're unaffected and that's really all the
  # toolchain files need by name.
  home.packages = [
    (lib.setPrio 15 pkgs.gcc15)
  ];
}
