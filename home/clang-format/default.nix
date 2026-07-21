_: {
  # YAML, no builtins.fromYAML in Nix and no dedicated Home Manager
  # module for clang-format, so linked raw.
  xdg.configFile."clang-format/.clang-format".source = ./.clang-format;
}
