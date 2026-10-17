{ pkgs, ... }:
{
  # dev-doctor checks what the dev module and the shell set up; toolchain
  # explains and selects the C/C++ compilers, and the shell's use_llvm,
  # use_gnu and use_system evaluate what it prints.
  home.packages = [ (pkgs.callPackage ./package.nix { }) ];

  # The Nix release this configuration's locked nixpkgs carries: the one
  # nix-darwin runs, and the one dev-bootstrap.sh --update-nix installs on
  # Linux. dev-doctor reports a daemon older than it.
  xdg.configFile."dev-doctor/nix-release".text = pkgs.nix.version;
}
