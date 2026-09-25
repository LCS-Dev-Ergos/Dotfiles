# The C/C++ toolchain every host, module and check uses, chosen in one place.
# Upgrading LLVM or GCC, or moving the macOS deployment target, is an edit to
# this file alone: the llvm and gcc modules beside it and the flake's
# toolchain check all read it, and none of them keeps a default of its own.
pkgs: {
  # Both must be prebuilt in cache.nixos.org for aarch64-darwin and
  # x86_64-linux: building GCC locally has failed here before. CI checks it on
  # every change, and reports when nixpkgs offers a newer GCC than this one.
  # Before raising either, this must list paths for both systems (add
  # `--system x86_64-linux` for the second):
  #   nix path-info --store https://cache.nixos.org --eval-store auto \
  #     --inputs-from . nixpkgs#gcc17.cc
  llvmPackages = pkgs.llvmPackages_22;
  gcc = pkgs.gcc16;

  # Policy: the oldest macOS that host-native binaries built here must run on.
  # It is a choice, not a fact about the running system -- following the OS
  # would move it at every macOS update and mix objects already sitting in
  # build caches. Evaluation rejects a value below nixpkgs' own floor, and the
  # toolchain check fails when the running macOS is older than it.
  darwinDeploymentTarget = "26.0";

  # Tripwire: the newest macOS SDK major this LLVM's LLD can read. LLD 22
  # rejects SDK 27's arm64e.x1 stubs, so the drivers hand a -fuse-ld=lld link
  # against a newer SDK to Apple's linker instead. It fires in two places:
  #  - evaluation fails as soon as llvmPackages is another LLVM major than
  #    `llvm`, until the ceiling has been re-established for that release;
  #  - the toolchain check fails when LLD links against a host SDK above the
  #    ceiling, which means the ceiling should rise.
  lld = {
    llvm = "22";
    newestSdkMajor = 26;
  };
}
