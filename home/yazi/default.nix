{ config, ... }:
{
  programs.yazi = {
    enable = true;
    # Parsed straight from the existing TOML rather than hand-transcribed,
    # same reasoning as starship/atuin: avoids transcription risk.
    settings = builtins.fromTOML (builtins.readFile ./yazi.toml);
    theme = builtins.fromTOML (builtins.readFile ./theme.toml);
  };

  # yazi.toml's [opener] rules use macOS-only commands (`open`, `open -R`).
  # Preserved as-is for the Mac; the Linux host (still unverified, no
  # access to test on) will need Linux openers added here later --
  # deliberately not guessing at a specific desktop environment's
  # "reveal in file manager" equivalent without being able to verify it.

  # The tokyo-night flavor is a live git checkout (same treatment as
  # bat's vendored syntax and tmux's plugins), kept writable via
  # mkOutOfStoreSymlink rather than folded into the read-only Nix store.
  xdg.configFile."yazi/flavors/tokyo-night.yazi".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/yazi/flavors/tokyo-night.yazi";
}
