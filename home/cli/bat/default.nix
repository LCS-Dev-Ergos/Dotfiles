{ externalSources, ... }:
{
  programs.bat = {
    enable = true;
    # Registers the theme under the name "tokyonight_night", matching the
    # existing file name so anything already using --theme=tokyonight_night
    # (e.g. a BAT_THEME env var set from the custom Zsh config)
    # keeps working unchanged. Home Manager runs `bat cache --build` for us.
    themes.tokyonight_night = {
      src = ./themes;
      file = "tokyonight_night.tmTheme";
    };

    # Vendored from https://github.com/victor-gp/cmd-help-sublime-syntax and
    # formerly kept as a writable nested checkout. Bat never mutates the grammar,
    # so pinning it as immutable source code gives reproducible updates; Home
    # Manager includes it in the same `bat cache --build` activation.
    syntaxes.cmd-help = {
      src = externalSources.cmdHelpSyntax;
      file = "syntaxes/cmd-help.sublime-syntax";
    };
  };
}
