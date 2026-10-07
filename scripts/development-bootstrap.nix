# Shared standalone entry for workstation bootstrap and CI. Read the locked
# public nixpkgs input without evaluating unrelated application flake inputs.
{
  system ? builtins.currentSystem,
  target ? "bootstrap",
}:
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  pkgs = import nixpkgs { inherit system; };
  targets.bootstrap = pkgs.callPackage ../home/dev/bootstrap/package.nix { };
  targets.cpp-tools = pkgs.callPackage ../home/dev/languages/cpp/cpp-tools.nix { };
  targets.ci = pkgs.mkShellNoCC {
    packages = [
      pkgs.actionlint
      pkgs.bash
      pkgs.deadnix
      pkgs.nixfmt
      pkgs.ripgrep
      pkgs.ruff
      pkgs.shellcheck
      pkgs.statix
    ];
  };
in
targets.${target}
