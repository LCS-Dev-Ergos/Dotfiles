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
    # Flip on once zsh itself moves to Home Manager (Step 5): until then
    # the still-Stow-managed zsh startup owns starship init, and enabling
    # this now would risk a double-init once both sides are active.
    enableZshIntegration = false;
  };

  # [custom.git_status] in starship.toml sources this by absolute runtime
  # path ($HOME/.config/starship/scripts/git_status.sh), so it has to be
  # placed there directly rather than folded into the generated TOML.
  xdg.configFile."starship/scripts/git_status.sh".source = ./scripts/git_status.sh;

  # The still-Stow-managed zsh config's STARSHIP_CONFIG env var points at
  # this legacy nested path (an artifact of the old Stow package layout,
  # where the repo mirrored $HOME under starship/.config/starship/).
  # programs.starship places its own output at the XDG-standard
  # ~/.config/starship.toml instead. Mirroring the same generated file
  # here, from the same settings, keeps the prompt working regardless of
  # which path a given shell resolves, without touching zsh itself.
  xdg.configFile."starship/starship.toml".source =
    (pkgs.formats.toml { }).generate "starship.toml" starshipSettings;
}
