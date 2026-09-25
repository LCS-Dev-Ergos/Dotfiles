{ pkgs, ... }:
{
  # Unison, whose code is stored by content hash rather than as text files;
  # `ucm` is its codebase manager, compiler and REPL.
  home.packages = [ pkgs.unison-ucm ];
}
