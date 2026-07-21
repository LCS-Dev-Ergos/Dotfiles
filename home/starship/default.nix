{ pkgs, ... }:
let
  # Parsed straight from the existing TOML rather than hand-transcribed
  # into a Nix attrset, since this config is large and any transcription
  # error would silently change prompt behaviour.
  starshipSettings = builtins.fromTOML (builtins.readFile ./starship.toml);
in
{
  programs.starship = {
    enable = true;
    settings = starshipSettings;
    # The custom Zsh startup now deployed by Home Manager still owns Starship
    # initialization. Enabling this integration would create a second init path.
    enableZshIntegration = false;
    # nushell's config.nu already has its own manual starship-init logic
    # (writing vendor/autoload/starship.nu); leaving this on would run a
    # second, independent init path (a `use ...` injected straight into
    # config.nu) alongside it.
    enableNushellIntegration = false;
  };

  # [custom.git_status] in starship.toml sources this by absolute runtime
  # path ($HOME/.config/starship/scripts/git_status.sh), so it has to be
  # placed there directly rather than folded into the generated TOML.
  xdg.configFile."starship/scripts/git_status.sh".source = ./scripts/git_status.sh;

  # The custom Zsh config's STARSHIP_CONFIG still points at this legacy nested
  # path, an artifact of the old Stow package layout where the repository
  # mirrored $HOME below starship/.config/starship/.
  # programs.starship places its own output at the XDG-standard
  # ~/.config/starship.toml instead. Mirroring the same generated file
  # here from the same settings keeps both resolution paths consistent while
  # retaining compatibility with that carefully migrated shell configuration.
  xdg.configFile."starship/starship.toml".source =
    (pkgs.formats.toml { }).generate "starship.toml"
      starshipSettings;
}
