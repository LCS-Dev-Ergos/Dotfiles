{ ... }:
{
  # LLDB's own custom command DSL, no Nix parser and no dedicated Home
  # Manager module. Lives directly at $HOME (not .config), so home.file
  # rather than xdg.configFile.
  home.file.".lldbinit".source = ./.lldbinit;
}
