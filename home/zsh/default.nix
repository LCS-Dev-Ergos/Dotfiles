{ lib, pkgs, ... }:
let
  # Keep the complete Zsh unit in one store path. Validation and dependency
  # tooling intentionally navigate from config/ to sibling packages and root
  # files; separate path copies would sever those read-only relationships.
  zshSource = ./.;
in
{
  # Keep file placement independent from programs.zsh. On Darwin, nix-darwin
  # owns the login-shell binary through users.users.<name>.shell
  # (hosts/lcs-macbook-pro/darwin.nix); standalone Home Manager installs the
  # package on Linux. This module only relocates configuration files.
  #
  # The custom config guards against double compinit (20-zinit.zsh runs it;
  # 85-completions.zsh checks whether initialization already happened).
  # Not using programs.zsh's own options at all means Home Manager never
  # generates a second compinit call to conflict with that.
  #
  # All shell source is store-backed. Runtime-generated completion dumps, lazy
  # loaders, path data, and traces already live below XDG cache/state paths;
  # source-adjacent .zwc compilation was retired because its small startup gain
  # did not justify a writable configuration tree or rollback-incompatible
  # bytecode. Durable edits now require a switch and follow Nix generations.
  home = {
    packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.zsh ];

    file = {
      ".zshenv".source = "${zshSource}/zshenv-bootstrap";
      ".zprofile".source = "${zshSource}/zprofile";
      ".zshrc".source = "${zshSource}/zshrc";
      ".p10k.zsh".source = "${zshSource}/p10k.zsh";
    };
  };

  xdg.configFile."zsh".source = "${zshSource}/config";
}
