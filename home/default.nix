{ lib, pkgs, ... }:
{
  # Host entrypoints import this shared layer plus exactly one platform layer.
  # Selecting platform imports there avoids consulting `pkgs` while the module
  # system is still resolving imports (which would create infinite recursion).
  imports = [ ./common.nix ];

  # Do not change after the first successful switch: it only pins which
  # Home Manager defaults apply, not the actual Home Manager/nixpkgs version.
  # system.stateVersion (hosts/lcs-macbook-pro/darwin.nix) plays the same
  # role for nix-darwin's own module defaults; the two are independent and
  # need not match.
  home.stateVersion = "26.05";

  # Fish sets this to true with mkDefault because it builds completions from man
  # pages. On Darwin with stateVersion >= 26.05, programs.man.package defaults
  # to null because macOS's /usr/bin/man already works without Nix managing it;
  # cache generation then has no effect and only emits a warning. Linux keeps
  # Home Manager's default and builds the caches normally.
  programs.man.generateCaches = lib.mkIf pkgs.stdenv.isDarwin false;
}
