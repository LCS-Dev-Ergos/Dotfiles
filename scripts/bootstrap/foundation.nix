# The installers dev-bootstrap.sh runs for missing foundations. The entry
# reads this file line by line under Bash 3.2, before Nix exists: keep one
# `name = "value";` per line. update-runtime-baseline.py checks both pins.
{
  # Homebrew's official installer at a reviewed commit of Homebrew/install.
  homebrewRevision = "ca45114992228ce6d708d49ef6becf5fb19100a1";
  homebrewSha256 = "8fd2f1a5287a7c2e3d7362924c677edcc04c5a0e16448c77132d056bc88cf1ed";
  # The official Nix installer for the release the locked nixpkgs carries;
  # the script holds each platform's tarball SHA-256.
  nixVersion = "2.35.6";
  nixSha256 = "6f7bf206efb54cd4941fb274930dbc74fdfc16fcb06757ef261c8d7d69cfd60e";
}
