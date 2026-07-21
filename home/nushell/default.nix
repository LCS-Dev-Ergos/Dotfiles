{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.nushell = {
    enable = true;
    # Embedded verbatim (no re-serialization). config.nu already has its
    # own manual `starship init nu` logic, so enableStarshipIntegration is
    # deliberately left off, matching starship's zsh/fish integration
    # options rather than letting Home Manager generate a second,
    # redundant autoload hook.
    extraConfig = builtins.readFile ./config.nu;
    envFile.text = builtins.readFile ./env.nu;
  };

  # Home Manager's nushell module places config at the macOS-native
  # ~/Library/Application Support/nushell/ (only when xdg.enable is false,
  # which it is by default on Darwin), but this system explicitly exports
  # XDG_CONFIG_HOME=~/.config (see zsh's lib/75-variables.zsh), and nushell
  # honours that over the platform default -- it was actually reading from
  # ~/.config/nushell/ before migration. Mirroring the exact same composed
  # output (which also carries the atuin fish/nu integration Home Manager
  # injects) at the XDG path keeps it working where nushell actually looks.
  #
  # Darwin-only: on Linux, cfg.configDir already resolves to
  # ${xdg.configHome}/nushell directly (an absolute-path home.file key that
  # IS the same target as xdg.configFile."nushell/*"), so this mirror would
  # collide with the module's own native output there instead of fixing
  # anything -- caught via the standard cross-host `nix eval` sanity check
  # on the Linux host.
  xdg.configFile."nushell/config.nu" = lib.mkIf pkgs.stdenv.isDarwin {
    source = config.home.file."Library/Application Support/nushell/config.nu".source;
  };
  xdg.configFile."nushell/env.nu" = lib.mkIf pkgs.stdenv.isDarwin {
    source = config.home.file."Library/Application Support/nushell/env.nu".source;
  };
}
