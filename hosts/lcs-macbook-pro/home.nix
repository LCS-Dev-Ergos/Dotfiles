{ homeDirectory, username, ... }:
{
  # Home Manager entrypoint for the Darwin host: the platform-neutral shared
  # layer (home/, imported by every host) plus the Darwin-only application
  # layer (home/darwin.nix). homeDirectory/username arrive as module
  # arguments from flake.nix's extraSpecialArgs, the same host facts also
  # threaded into nix-darwin's specialArgs for this host.
  home = {
    inherit username homeDirectory;
  };

  imports = [
    ../../home
    ../../home/darwin.nix
  ];
}
