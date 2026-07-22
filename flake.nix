{
  description = "LCS-Dev dotfiles flake (macOS + Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Immutable application assets. Third-party code is pinned here; the few
    # runtime-mutable paths that cannot yet be store-backed are documented in
    # home/out-of-store-allowlist.tsv.
    alacritty-theme = {
      url = "github:alacritty/alacritty-theme/94e1dc0b9511969a426208fbba24bd7448493785";
      flake = false;
    };
    cmd-help-syntax = {
      url = "github:victor-gp/cmd-help-sublime-syntax/273cb988177e96f4187e06008b13fa72ad22ae4d";
      flake = false;
    };
    sbarlua = {
      url = "github:FelixKratz/SbarLua/dba9cc421b868c918d5c23c408544a28aadf2f2f";
      flake = false;
    };
    tokyo-night-yazi = {
      url = "github:BennyOe/tokyo-night.yazi/5f5636427f9bb16cc3f7c5e5693c60914c73f036";
      flake = false;
    };
    tpm = {
      url = "github:tmux-plugins/tpm/99469c4a9b1ccf77fade25842dc7bafbc8ce9946";
      flake = false;
    };
    tokyo-night-tmux = {
      url = "github:janoamaral/tokyo-night-tmux/caf6cbb4c3a32d716dfedc02bc63ec8cf238f632";
      flake = false;
    };
    vim-tmux-navigator = {
      url = "github:christoomey/vim-tmux-navigator/412c474e97468e7934b9c217064025ea7a69e05e";
      flake = false;
    };
    tmux-resurrect = {
      url = "github:tmux-plugins/tmux-resurrect/cff343cf9e81983d3da0c8562b01616f12e8d548";
      flake = false;
    };
    tmux-continuum = {
      url = "github:tmux-plugins/tmux-continuum/0698e8f4b17d6454c71bf5212895ec055c578da0";
      flake = false;
    };
    smart-tmux-session-manager = {
      url = "github:joshmedeski/t-smart-tmux-session-manager/3726950525ac9966412ea3f2093bf2ffe06aa023";
      flake = false;
    };
    tmux-yank = {
      url = "github:tmux-plugins/tmux-yank/acfd36e4fcba99f8310a7dfb432111c242fe7392";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nix-darwin,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      # Host facts live here rather than inside shared modules. In particular,
      # dotfilesRoot is the real checkout used by out-of-store symlinks; deriving
      # it from a store-copied flake path would silently make writable configs
      # read-only again.
      darwinHost = rec {
        system = "aarch64-darwin";
        username = "lcs-dev";
        homeDirectory = "/Users/${username}";
        dotfilesRoot = "${homeDirectory}/Dotfiles";
      };
      linuxHost = rec {
        system = "x86_64-linux";
        username = "lcs-dev";
        homeDirectory = "/home/${username}";
        dotfilesRoot = "${homeDirectory}/Dotfiles";
      };
      externalSources = {
        alacrittyTheme = inputs.alacritty-theme;
        cmdHelpSyntax = inputs.cmd-help-syntax;
        sbarLua = inputs.sbarlua;
        tokyoNightYazi = inputs.tokyo-night-yazi;
        tmuxPlugins = {
          inherit (inputs) tpm;
          tokyoNight = inputs.tokyo-night-tmux;
          vimNavigator = inputs.vim-tmux-navigator;
          resurrect = inputs.tmux-resurrect;
          continuum = inputs.tmux-continuum;
          smartSessionManager = inputs.smart-tmux-session-manager;
          yank = inputs.tmux-yank;
        };
      };
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      homeArgs = host: {
        inherit externalSources;
        inherit (host) dotfilesRoot homeDirectory username;
      };
    in
    {
      # Build darwin flake using:
      # $ darwin-rebuild build --flake .#LCSMacBook-Pro
      darwinConfigurations."LCSMacBook-Pro" = nix-darwin.lib.darwinSystem {
        specialArgs = {
          inherit self;
          inherit (darwinHost) homeDirectory username;
        };
        modules = [
          ./darwin
          ./hosts/lcs-macbook-pro/darwin.nix
          home-manager.darwinModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = homeArgs darwinHost;
              users.${darwinHost.username} = import ./hosts/lcs-macbook-pro/home.nix;
            };
          }
        ];
      };

      # Standalone Home Manager, no nix-darwin equivalent: Arch Linux keeps
      # its own package manager responsible for the OS. Hostname taken from
      # the Tailscale MagicDNS entry in known_hosts (lcs-legion-arch...ts.net);
      # x86_64-linux is a provisional guess — neither is confirmed until
      # there's access to the actual machine again. Written but unverified:
      # cannot build or switch this from the Mac without a configured Linux
      # remote builder.
      # $ nix build '.#homeConfigurations."lcs-dev@lcs-legion-arch".activationPackage'
      homeConfigurations."lcs-dev@lcs-legion-arch" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit (linuxHost) system;
          config.allowUnfree = false;
        };
        extraSpecialArgs = homeArgs linuxHost;
        modules = [ ./hosts/lcs-legion-arch/home.nix ];
      };

      checks = {
        aarch64-darwin.darwin-configuration = self.darwinConfigurations."LCSMacBook-Pro".system;
        x86_64-linux.home-configuration =
          self.homeConfigurations."lcs-dev@lcs-legion-arch".activationPackage;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      # A small, lockfile-pinned tool environment shared by local verification
      # and CI. Keeping these tools on the flake input avoids silently linting
      # with whatever revision the runner's global nixpkgs registry provides.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          ci = pkgs.mkShellNoCC {
            packages = [
              pkgs.bash
              pkgs.deadnix
              pkgs.nixfmt
              pkgs.ripgrep
              pkgs.shellcheck
              pkgs.statix
            ];
          };
        }
      );
    };
}
