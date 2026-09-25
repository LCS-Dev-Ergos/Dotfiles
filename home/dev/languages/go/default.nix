{ pkgs, ... }:
{
  # Go is pinned to a release rather than to `pkgs.go`, which nixpkgs moves to
  # a new release only some weeks after it ships. Bump the attribute when a
  # new Go release reaches the binary cache.
  home.packages = [ pkgs.go_1_27 ];
}
