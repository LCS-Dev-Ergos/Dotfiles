{ ... }:
{
  # Primarily a Linux/X11 terminal-image tool, mostly inert on this Mac,
  # but preserved unchanged. No dedicated Home Manager module; plain JSON
  # is small enough that raw linking is simplest and lowest-risk.
  xdg.configFile."ueberzugpp/config.json".source = ./config.json;
}
