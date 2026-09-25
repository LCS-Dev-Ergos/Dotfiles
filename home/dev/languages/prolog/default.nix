{ pkgs, ... }:
{
  # SWI-Prolog, on both hosts.
  home.packages = [ pkgs.swi-prolog ];
}
