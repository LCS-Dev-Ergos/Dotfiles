{ pkgs, ... }:
{
  # Koka, a functional language built around algebraic effect handlers and
  # Perceus reference counting. It compiles through C, with the host CC from
  # home/dev/toolchains/llvm.
  home.packages = [ pkgs.koka ];
}
