{
  externalSources,
  lib,
  pkgs,
  ...
}:
let
  baseSettings = builtins.fromTOML (builtins.readFile ./yazi.toml);
  linuxOpeners = {
    inherit (baseSettings.opener) edit;
    open = [
      {
        run = ''xdg-open "$@"'';
        desc = "Open with system default";
      }
    ];
    reveal = [
      {
        run = ''xdg-open "$(dirname "$1")"'';
        desc = "Reveal in file manager";
      }
    ];
  };
in
{
  programs.yazi = {
    enable = true;
    # Parsed straight from the existing TOML rather than hand-transcribed,
    # same reasoning as starship/atuin: avoids transcription risk.
    settings = baseSettings // lib.optionalAttrs pkgs.stdenv.isLinux { opener = linuxOpeners; };
    theme = builtins.fromTOML (builtins.readFile ./theme.toml);
  };

  # The source TOML intentionally retains macOS `open`/`open -R` rules. Linux
  # replaces only that platform-specific opener block with xdg-open: it is
  # desktop-neutral, and revealing the parent directory is the safest portable
  # fallback without guessing a particular untested file manager's CLI.

  # The flavor was formerly a writable vendored checkout. Yazi does not write
  # into it, so immutable lock-file pinning is the appropriate treatment and
  # avoids silent appearance changes after an in-place `git pull`.
  xdg.configFile."yazi/flavors/tokyo-night.yazi".source = externalSources.tokyoNightYazi;
}
