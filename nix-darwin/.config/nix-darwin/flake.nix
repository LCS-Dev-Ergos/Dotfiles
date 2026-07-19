{
  description = "LCS-Dev macOS system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs, home-manager }:
  let

    # Root of the dotfiles repo, used by Home Manager modules to source
    # config files (e.g. Kitty, Neovim) without fragile relative paths.
    dotfilesRoot = "/Users/lcs-dev/Dotfiles";

    configuration = { pkgs, config, ... }: {
      # List packages installed in system profile. To search by name, run:
      # $ nix-env -qaP | grep wget
      environment.systemPackages =
        [ pkgs.vim
        ];

      # Auto upgrade nix package and the daemon service.
      nix.enable = true;
      # nix.package = pkgs.nix;

      # Necessary for using flakes on this system.
      nix.settings.experimental-features = "nix-command flakes";

      # Zsh is managed by the Stow configuration until its future migration to
      # Home Manager. nix-darwin must not generate /etc/zsh* configuration.
      programs.zsh.enable = false;
      # programs.fish.enable = true;

      # Set Git commit hash for darwin-version.
      system.configurationRevision = self.rev or self.dirtyRev or null;

      # Used for backwards compatibility, please read the changelog before changing.
      # $ darwin-rebuild changelog
      system.stateVersion = 4;

      # The platform the configuration will be used on.
      nixpkgs.hostPlatform = "aarch64-darwin";
 
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#LCSMacBook-Pro
    darwinConfigurations."LCSMacBook-Pro" = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit dotfilesRoot; };
      modules = [
        configuration
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit dotfilesRoot; };
          home-manager.users."lcs-dev" = import ./home.nix;
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."LCSMacBook-Pro".pkgs;

  };
}
