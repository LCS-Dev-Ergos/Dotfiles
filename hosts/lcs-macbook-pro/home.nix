{ homeDirectory, username, ... }:
{
  home = {
    inherit username homeDirectory;
  };

  imports = [
    ../../home
    ../../home/darwin.nix
  ];
}
