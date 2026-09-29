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
    # Both status bars consume the same CPU sample on a one-second cadence.
    cadences.cpu = 1000;
    # An observed Homebrew check took 8.2 seconds, close to the default deadline.
    packageTimeoutMs = if pkgs.stdenv.hostPlatform.isDarwin then 30000 else 10000;
  };
}
