{ pkgs, ... }:
{
  # System-wide C/C++ toolchain, replacing Homebrew's keg-only llvm. Homebrew
  # ships clang unwrapped -- no macOS SDK auto-detection -- so anything that
  # needs SDK headers fails unless SDKROOT/CPATH/LIBRARY_PATH are set by hand
  # (that's what broke compiling ada_language_server's C stubs, for example).
  # Nix's clang wrapper bakes in the right -isysroot itself, verified
  # empirically: it compiled the same failing file with zero env vars via a
  # throwaway `nix shell`.
  # PATH priority over Homebrew is handled in home/zsh (Nix already wins there).
  home.packages = [
    pkgs.llvmPackages_22.clang
    pkgs.llvmPackages_22.clang-tools
    pkgs.llvmPackages_22.lld
    pkgs.llvmPackages_22.lldb
  ];
}
