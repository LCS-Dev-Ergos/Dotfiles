{ pkgs, ... }:
{
  # Not using programs.btop.settings: Home Manager's generator writes
  # booleans as Python-style True/False, but btop's own parser expects
  # lowercase true/false (as the original file uses throughout) — silently
  # wrong, not just uncommented. Linking the raw file preserves both the
  # comments and the exact casing btop actually parses.
  programs.btop.enable = true;

  # @btopTokyoNightTheme@ replaces the original's hardcoded Homebrew
  # Cellar path (verified byte-identical to this bundled copy), which
  # would silently break once btop no longer comes from Homebrew.
  xdg.configFile."btop/btop.conf".source = pkgs.replaceVars ./btop.conf {
    btopTokyoNightTheme = "${pkgs.btop}/share/btop/themes/tokyo-night.theme";
  };
}
