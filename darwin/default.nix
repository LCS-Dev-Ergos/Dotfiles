{ lib, pkgs, ... }:
{
  imports = [ ./homebrew.nix ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [ pkgs.vim ];

  # Doom uses Symbola as its final fallback for uncommon glyphs. Homebrew no
  # longer distributes the font, so nix-darwin installs the pinned package in
  # the system font directory where GUI Emacs and fontconfig can both find it.
  fonts.packages = [ pkgs.symbola ];

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

  # Keep unfree Nix packages denied by default. Symbola is the sole reviewed
  # exception: nixpkgs marks its font license non-free, and Homebrew no longer
  # ships it. Proprietary GUI applications remain Homebrew-owned.
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "symbola";

  # Home Manager deploys the user's Zsh files. Homebrew still owns the Darwin
  # shell binary (standalone Home Manager installs it on Linux), so nix-darwin
  # must not generate a competing /etc/zsh* configuration or integration path.
  programs.zsh.enable = false;
}
