{ lib, pkgs, ... }:
{
  programs.fastfetch = {
    enable = true;
    # nixpkgs puts apple-sdk_15 among fastfetch's runtime libraries on Darwin,
    # which keeps a whole 418 MB SDK alive for a search path holding only
    # linker stubs, never a loadable library. Dropping it leaves the one SDK
    # that GCC and Python cannot shed as the only Apple SDK in the closure.
    package = pkgs.fastfetch.override {
      runtimeDependencies = builtins.filter (
        dependency: !(lib.hasPrefix "apple-sdk" (lib.getName dependency))
      ) pkgs.fastfetch.runtimeDependencies;
    };
  };

  # config.jsonc is JSON-with-comments; Nix's builtins.fromJSON is strict
  # JSON and errors on comments, so this is linked raw rather than routed
  # through programs.fastfetch.settings.
  xdg.configFile = {
    "fastfetch/config.jsonc".source = ./config.jsonc;
    "fastfetch/pngs" = {
      source = ./pngs;
      recursive = true;
    };
    "fastfetch/scripts" = {
      source = ./scripts;
      recursive = true;
    };
  };
}
