{ pkgs, lib, config, ... }:
{
  # The user isn't using aerospace daily -- yabai is the actual window
  # manager in use. start-at-login = true in the source file was
  # aspirational/experimental, not current intent: enabling
  # launchd.enable = true (see prior revision) actually auto-started
  # aerospace, which conflicted with yabai and got killed by macOS.
  # start-at-login is force-overridden to false here so aerospace never
  # auto-starts via either mechanism, while the rest of the config stays
  # intact in case it's revisited later.
  # settings (not userSettings) is used for full replacement rather than
  # a merge with Home Manager's own base defaults, avoiding the kind of
  # unverified extra-settings injection found with tmux's typed options.
  programs.aerospace = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    settings = (builtins.fromTOML (builtins.readFile ./aerospace.toml)) // {
      start-at-login = false;
    };
    launchd.enable = false;
  };

  # programs.aerospace places its output at the top-level ~/.aerospace.toml
  # (AeroSpace's first config search location), not the XDG-style
  # ~/.config/aerospace/aerospace.toml the original Stow package used.
  # AeroSpace should find the top-level one first regardless, but
  # mirroring the exact composed output at the old path too costs nothing
  # and removes any doubt, same defensive move as nushell/tealdeer.
  xdg.configFile."aerospace/aerospace.toml" = lib.mkIf pkgs.stdenv.isDarwin {
    source = config.home.file.".aerospace.toml".source;
  };
}
