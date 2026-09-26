{
  config,
  herdr,
  lib,
  pkgs,
  ...
}:
let
  runtimeConfigDir = "${config.xdg.stateHome}/herdr";
  runtimeConfig = "${runtimeConfigDir}/config.toml";
in
{
  home = {
    # herdr isn't packaged in nixpkgs; the `herdr` argument is upstream's own
    # flake build, resolved per-system in flake.nix's homeArgs and threaded
    # through the same way externalSources is.
    packages = [ herdr ];

    # herdr rewrites config.toml itself (theme picker, sound, toast delivery,
    # agent panel sort, ...), so a store-backed symlink at the default XDG
    # path fails those writes with EPERM. Same shape as Neovim's
    # lazy-lock.json: sync a writable runtime copy from this declared source
    # on every activation, so the file stays authoritative across switches,
    # and point herdr at it via HERDR_CONFIG_PATH instead of leaving
    # anything at ~/.config/herdr.
    sessionVariables.HERDR_CONFIG_PATH = runtimeConfig;

    activation.syncHerdrConfig = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      if [[ -v DRY_RUN ]]; then
        printf 'Would sync %s from the active generation\n' \
          ${lib.escapeShellArg runtimeConfig}
      else
        ${pkgs.coreutils}/bin/install -d -m 0700 \
          ${lib.escapeShellArg runtimeConfigDir}
        ${pkgs.coreutils}/bin/install -m 0600 \
          ${lib.escapeShellArg (toString ./config.toml)} \
          ${lib.escapeShellArg "${runtimeConfig}.new"}
        ${pkgs.coreutils}/bin/mv -f \
          ${lib.escapeShellArg "${runtimeConfig}.new"} \
          ${lib.escapeShellArg runtimeConfig}
      fi
    '';
  };
}
