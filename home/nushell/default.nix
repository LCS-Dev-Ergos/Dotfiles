{ config, ... }:
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
  # ~/Library/Application Support/nushell/, but this system explicitly
  # exports XDG_CONFIG_HOME=~/.config (see zsh's lib/75-variables.zsh),
  # and nushell honours that over the platform default -- it was actually
  # reading from ~/.config/nushell/ before migration. Mirroring the exact
  # same composed output (which also carries the atuin fish/nu
  # integration Home Manager injects) at the XDG path keeps it working
  # where nushell actually looks.
  xdg.configFile."nushell/config.nu".source =
    config.home.file."Library/Application Support/nushell/config.nu".source;
  xdg.configFile."nushell/env.nu".source =
    config.home.file."Library/Application Support/nushell/env.nu".source;
}
