{
  pkgs,
  lib,
  ...
}:
let
  inherit (import ../../toolchains/cc-toolchain.nix pkgs) gcc;
  # The Fortran front end of the same GCC release the C/C++ toolchain uses,
  # so mixed-language builds link against one libgcc and one runtime.
  gfortran = pkgs."gfortran${lib.versions.major gcc.version}";
in
{
  # gfortran on Linux. On Darwin it comes from Homebrew's gcc, which stays
  # installed for the formulae that depend on it (see darwin/homebrew.nix)
  # and is the same GCC release, so a second copy would add nothing.
  #
  # The wrapper also ships gcc, g++, cc and binutils. setPrio 20 lets the C
  # toolchain's wrappers (clang at 10, gcc at 15) keep those names, so this
  # package contributes only gfortran and its f77/g77 aliases.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (lib.setPrio 20 gfortran)
  ];
}
