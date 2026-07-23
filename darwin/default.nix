{ lib, pkgs, ... }:
let
  # The retired Homebrew cask supplied only this face. Copying it into a small
  # output keeps the active system closure from retaining every Noto family;
  # pkgs.noto-fonts remains the lockfile-pinned build source.
  notoSansSymbols2 = pkgs.runCommand "noto-sans-symbols-2-${pkgs.noto-fonts.version}" { } ''
    install -Dm444 \
      ${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf \
      "$out/share/fonts/opentype/NotoSansSymbols2-Regular.otf"
  '';
in
{
  imports = [ ./homebrew.nix ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [ pkgs.vim ];

  # Install open fonts through nix-darwin so GUI applications and fontconfig
  # see the same pinned families. Apple-proprietary SF fonts remain casks.
  # Symbola is Doom's final fallback for uncommon glyphs; CM Unicode is the
  # exact family previously supplied by Homebrew's font-computer-modern cask.
  fonts.packages = [
    pkgs.cm_unicode
    pkgs.fira-code
    pkgs.nerd-fonts.caskaydia-cove
    pkgs.nerd-fonts.fira-code
    pkgs.nerd-fonts.hack
    pkgs.nerd-fonts.iosevka
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.nerd-fonts.monaspace
    pkgs.nerd-fonts.symbols-only
    notoSansSymbols2
    pkgs.symbola
  ];

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
  # ships it. The other Nix-managed fonts above are freely licensed;
  # proprietary applications and Apple fonts remain Homebrew-owned.
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "symbola";

  # Home Manager deploys the user's Zsh files, and the login shell is the Nix
  # zsh package via users.users.<name>.shell (hosts/lcs-macbook-pro/darwin.nix).
  # Keep this module disabled regardless: it would generate /etc/zshenv,
  # /etc/zprofile, and /etc/zshrc with a competing global compinit, while the
  # repository .zshenv already provides the Nix environment for all shell types.
  programs.zsh.enable = false;
}
