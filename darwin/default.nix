{ pkgs, ... }:
{
  imports = [ ./homebrew.nix ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [ pkgs.vim ];

  nix = {
    # Keep the Nix package and daemon service managed by nix-darwin. Flakes
    # require both experimental features until they become universally stable.
    enable = true;
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Declarative equivalent of routine `nix-collect-garbage`/store optimisation:
    # prune old generations automatically and hardlink duplicate store files.
    # Fourteen days preserves a useful rollback margin while the migration
    # settles instead of requiring either manual cleanup or aggressive pruning.
    gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    optimise.automatic = true;
  };

  # All Nix-installed packages must be explicitly free-licensed. Homebrew
  # remains the owner for proprietary GUI applications.
  nixpkgs.config.allowUnfree = false;

  # Home Manager deploys the user's Zsh files. Homebrew still owns the Darwin
  # shell binary (standalone Home Manager installs it on Linux), so nix-darwin
  # must not generate a competing /etc/zsh* configuration or integration path.
  programs.zsh.enable = false;
}
