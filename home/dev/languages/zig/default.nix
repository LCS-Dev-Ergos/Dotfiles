{ pkgs, ... }:
{
  # Zig, globally and on both hosts. Doom's zig module uses the same binary;
  # the language is owned here so it outlives any editor configuration.
  #
  # `zig cc` cannot use the host toolchain from home/dev/toolchains/llvm: Zig compiles C and
  # C++ with the Clang it is built from (its own LLVM release) and links with
  # its own linker. It does find the host SDK through xcrun on its own.
  home.packages = [ pkgs.zig ];
}
