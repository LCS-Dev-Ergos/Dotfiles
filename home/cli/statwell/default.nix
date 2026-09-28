{
  config,
  lib,
  pkgs,
  statwellModule,
  statwellPackage,
  ...
}:
{
  imports = [ statwellModule ];

  # One user daemon feeds the status surfaces on either supported host.
  services.statwell = {
    enable = true;
    package = statwellPackage;
    diskPath = config.home.homeDirectory;
    networkInterface = if pkgs.stdenv.hostPlatform.isDarwin then "en0" else null;
    providers = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "homebrew" ];
  };
}
