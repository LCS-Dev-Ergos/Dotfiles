{
  description = "LCS-Dev dotfiles flake (macOS + Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs, home-manager }:
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#LCSMacBook-Pro
    darwinConfigurations."LCSMacBook-Pro" = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit self; };
      modules = [
        ./darwin
        ./hosts/LCSMacBook-Pro/darwin.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users."lcs-dev" = import ./hosts/LCSMacBook-Pro/home.nix;
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."LCSMacBook-Pro".pkgs;

    # Standalone Home Manager, no nix-darwin equivalent: Arch Linux keeps
    # its own package manager responsible for the OS. Hostname taken from
    # the Tailscale MagicDNS entry in known_hosts (lcs-legion-arch...ts.net);
    # x86_64-linux is a provisional guess — neither is confirmed until
    # there's access to the actual machine again. Written but unverified:
    # cannot build or switch this from the Mac without a configured Linux
    # remote builder.
    # $ nix build --impure '.#homeConfigurations."lcs-dev@lcs-legion-arch".activationPackage'
    homeConfigurations."lcs-dev@lcs-legion-arch" = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      modules = [ ./hosts/lcs-legion-arch/home.nix ];
    };
  };
}
