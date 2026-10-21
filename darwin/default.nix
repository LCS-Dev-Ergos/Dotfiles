{ pkgs, ... }:
{
  imports = [
    ./homebrew.nix
    ./window-manager.nix
    ../home/desktop/shared/fonts/darwin.nix
  ];

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
    # Seven days preserve a useful rollback margin on this stable system
    # without retaining old generations long enough to waste disk space.
    gc = {
      automatic = true;
      options = "--delete-older-than 7d";
    };
    optimise.automatic = true;
  };

  # macOS's stock sudoers doesn't set always_set_home, so $HOME stays the
  # invoking user's home even when running as root. Nix >=2.19 notices that
  # mismatch and falls back to root's real home from the passwd file -- this
  # setting makes sudo do the reset itself, matching `sudo -H`, so root-run
  # Nix commands (including the automatic GC above) see root's own $HOME.
  environment.etc."sudoers.d/20-always-set-home".text = ''
    Defaults always_set_home
  '';

  # Home Manager deploys the user's Zsh files, and the login shell is the Nix
  # zsh package via users.users.<name>.shell (hosts/lcs-macbook-pro/darwin.nix).
  # Keep this module disabled regardless: it would generate /etc/zshenv,
  # /etc/zprofile, and /etc/zshrc with a competing global compinit, while the
  # repository .zshenv already provides the Nix environment for all shell types.
  programs.zsh.enable = false;
}
