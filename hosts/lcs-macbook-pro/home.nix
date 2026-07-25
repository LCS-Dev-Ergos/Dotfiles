{ homeDirectory, username, ... }:
{
  # Home Manager entrypoint for the Darwin host: the platform-neutral shared
  # layer (home/, imported by every host) plus the Darwin-only application
  # layer (home/darwin.nix). homeDirectory/username arrive as module
  # arguments from flake.nix's extraSpecialArgs, the same host facts also
  # threaded into nix-darwin's specialArgs for this host.
  #
  # Under nix-darwin these two are strictly redundant: Home Manager's
  # integration already derives them from users.users.<name>. They stay because
  # the Linux host runs standalone and has no such record, so both entrypoints
  # keep the same shape -- and because home.username/homeDirectory merge by
  # equality, a future divergence between the host record and the account
  # declaration fails evaluation here instead of activating something wrong.
  home = {
    inherit username homeDirectory;
  };

  imports = [
    ../../home
    ../../home/darwin.nix
  ];
}
