{ lib, ... }:
{
  programs.atuin = {
    enable = true;
    # Parsed straight from the existing TOML rather than hand-transcribed,
    # same reasoning as starship: avoids transcription risk entirely.
    settings = builtins.fromTOML (builtins.readFile ./config.toml);
  };

  # atuin regenerates its own stock default config.toml on every new shell
  # (a shell-integration hook, not just a one-off first-run), so a manual
  # rm doesn't stay removed -- force lets Home Manager clobber it on every
  # switch instead of erroring on the collision.
  xdg.configFile."atuin/config.toml".force = lib.mkForce true;

  # config.toml's [theme] name = "tokyonight" references this file; atuin
  # doesn't have a dedicated Home Manager option for it, so it's placed
  # directly at its expected path.
  xdg.configFile."atuin/themes/tokyonight.toml".source = ./themes/tokyonight.toml;
}
