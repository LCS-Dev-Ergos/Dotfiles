{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.tealdeer = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ./config.toml);
  };

  # Same issue as nushell: Home Manager's tealdeer module places config at
  # the macOS-native ~/Library/Application Support/tealdeer/, but this
  # system exports XDG_CONFIG_HOME=~/.config (home/zsh/zprofile), which
  # tealdeer (a Rust/directories-rs tool) honours -- it was reading
  # from ~/.config/tealdeer/ before migration. Mirroring the exact
  # composed output at the XDG path keeps it working.
  #
  # Darwin-only: on Linux the module already writes straight to the XDG
  # path natively, so this mirror would collide with its own output there
  # instead of fixing anything (same cross-host issue as nushell's).
  xdg.configFile."tealdeer/config.toml" = lib.mkIf pkgs.stdenv.isDarwin {
    source = config.home.file."Library/Application Support/tealdeer/config.toml".source;
  };
}
