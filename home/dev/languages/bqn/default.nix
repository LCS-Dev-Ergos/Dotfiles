{ pkgs, ... }:
{
  # BQN, an array language in the APL family with an ASCII-friendly design
  # and first-class functions. CBQN is the reference native implementation.
  home.packages = [ pkgs.cbqn ];
}
