{
  config,
  lib,
  pkgs,
  ...
}:
let
  fishVariablesState = "${config.xdg.stateHome}/fish/fish_variables";
in
{
  programs.fish = {
    enable = true;
    interactiveShellInit = builtins.readFile ./config.fish;
  };

  # rustup's own fish hook (sources ~/.cargo/env.fish); conf.d/*.fish files
  # are auto-sourced by fish on startup, so this just needs to land there.
  xdg.configFile."fish/conf.d/rustup.fish".source = ./rustup.fish;

  # fish_variables is application-owned universal-variable state. Seed the
  # current color and key-binding defaults once, then let Fish mutate a private
  # state file instead of the repository. entryBefore guarantees that the
  # out-of-store link has a target when Home Manager installs the generation;
  # the existence check makes later activations non-destructive.
  home.activation.seedFishVariables = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    if [[ ! -e ${lib.escapeShellArg fishVariablesState} ]]; then
      if [[ -v DRY_RUN ]]; then
        printf 'Would seed %s\n' ${lib.escapeShellArg fishVariablesState}
      else
        ${pkgs.coreutils}/bin/install -D -m 0600 \
          ${lib.escapeShellArg (toString ./fish_variables)} \
          ${lib.escapeShellArg fishVariablesState}
      fi
    fi
  '';

  xdg.configFile."fish/fish_variables".source =
    config.lib.file.mkOutOfStoreSymlink fishVariablesState;

  # completions/docker.fish, kubectl.fish, orbctl.fish were symlinks
  # OrbStack itself installed, pointing into /Applications/OrbStack.app/.
  # Not portable dotfiles content (and wrong on the Linux host), so they
  # were dropped rather than migrated; OrbStack will recreate them.
}
