# The C/C++ toolchain every host, module and check uses, chosen in one place.
# Upgrading LLVM or GCC, or moving the macOS deployment target, is an edit to
# this file alone: the llvm and gcc modules beside it and the flake's
# toolchain check all read it, and none of them keeps a default of its own.
pkgs:
let
  llvmPackages = pkgs.llvmPackages_23;
in
{
  # Both must be prebuilt in cache.nixos.org for aarch64-darwin and
  # x86_64-linux: building GCC locally has failed here before. CI checks it on
  # every change, and reports when nixpkgs offers a newer GCC than this one.
  # Before raising either, this must list paths for both systems (add
  # `--system x86_64-linux` for the second):
  #   nix path-info --store https://cache.nixos.org --eval-store auto \
  #     --inputs-from . nixpkgs#gcc17.cc
  inherit llvmPackages;
  gcc = pkgs.gcc16;

  # The debugger may trail the compiler by one release. LLDB 23.1.0 does not
  # build on Darwin in nixpkgs yet: its build signs the binary through
  # `xcrun codesign`, which the sandbox does not have, so Hydra publishes no
  # binary. LLDB 22 reads what Clang 23 emits; drop the exception once
  # `nix path-info --store https://cache.nixos.org --eval-store auto
  # --inputs-from . nixpkgs#llvmPackages_23.lldb` finds a path.
  lldb = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.llvmPackages_22.lldb else llvmPackages.lldb;

  # Policy: the oldest macOS that host-native binaries built here must run on.
  # It is a choice, not a fact about the running system -- following the OS
  # would move it at every macOS update and mix objects already sitting in
  # build caches. Evaluation rejects a value below nixpkgs' own floor, and the
  # toolchain check fails when the running macOS is older than it.
  darwinDeploymentTarget = "26.0";

  # Tripwire: the newest macOS SDK major this LLVM's LLD can read. LLD 23.1.0
  # still rejects SDK 27's arm64e.x1 stubs (support is being backported to
  # the 23.x branch in llvm/llvm-project#224185), so the drivers hand a
  # -fuse-ld=lld link against a newer SDK to Apple's linker instead. It fires
  # in two places:
  #  - evaluation fails as soon as llvmPackages is another LLVM major than
  #    `llvm`, until the ceiling has been re-established for that release;
  #  - the toolchain check fails when LLD links against a host SDK above the
  #    ceiling, which means the ceiling should rise.
  lld = {
    llvm = "23";
    newestSdkMajor = 26;
  };
}
