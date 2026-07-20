{ ... }:
{
  # Kitty never writes back into its own config directory at runtime, so
  # a plain store copy is fine: editing the file requires `darwin-rebuild
  # switch` to take effect, which is the standard immutable Nix behaviour.
  xdg.configFile."kitty" = {
    source = ./kitty;
    recursive = true;
  };
}
