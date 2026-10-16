# Shared standalone entry for workstation bootstrap and CI. Read the locked
# public nixpkgs input without evaluating unrelated application flake inputs.
{
  system ? builtins.currentSystem,
  target ? "bootstrap",
}:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  pkgs = import nixpkgs { inherit system; };
  targets.bootstrap = pkgs.callPackage ../../home/dev/bootstrap/package.nix { };
  targets.cpp-tools = pkgs.callPackage ../../home/dev/languages/cpp/cpp-tools.nix { };
  targets.ci = pkgs.mkShellNoCC {
    packages = [
      pkgs.actionlint
      pkgs.bash
      pkgs.deadnix
      pkgs.nixfmt
      pkgs.python3
      pkgs.ripgrep
      pkgs.ruff
      pkgs.shellcheck
      pkgs.statix
    ];
  };
  # The Nix compiler drivers macOS source builds use, for a host whose Home
  # Manager profile does not provide them yet (the native CI runner, whose
  # harness links this as its disposable home's profile). Runtime libraries
  # stay referenced in the store: no home directory relocates them.
  targets.toolchain = pkgs.callPackage ../../home/dev/toolchains/llvm/package.nix {
    ccToolchain = import ../../home/dev/toolchains/cc-toolchain.nix pkgs;
    homeDirectory = null;
  };
  # scripts/updates/update-runtime-baseline.py reads GHCup's YAML metadata.
  targets.freshness = pkgs.mkShellNoCC {
    packages = [ (pkgs.python3.withPackages (python: [ python.pyyaml ])) ];
  };
in
targets.${target}
