{ homeDirectory, username, ... }:
{
  # Home Manager entrypoint for the Linux host, run standalone (no nix-darwin
  # equivalent -- Arch Linux keeps its own package manager responsible for the
  # OS). Same composition as the Darwin host: the platform-neutral shared
  # layer (home/) plus the Linux-only application layer (home/linux.nix).
  # homeDirectory/username arrive as module arguments from flake.nix's
  # extraSpecialArgs; see flake.nix for this host's unverified status.
  home = {
    inherit username homeDirectory;
  };

  imports = [
    ../../home
    ../../home/linux.nix
  ];
}
