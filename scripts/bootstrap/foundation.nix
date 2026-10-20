# The installers dev-bootstrap.sh runs for missing foundations. The entry
# reads this file line by line under Bash 3.2, before Nix exists: keep one
# `name = "value";` per line. update-runtime-baseline.py checks both pins.
{
  # Homebrew's official installer at a reviewed commit of Homebrew/install.
  homebrewRevision = "8ab1549dfa1189fd4d818a2116592d8f0ee06d8c";
  homebrewSha256 = "5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148";
  # The official Nix installer for the release the locked nixpkgs carries;
  # the script holds each platform's tarball SHA-256.
  nixVersion = "2.34.9";
  nixSha256 = "a03ce2e9eaf4ea1560260b9a93e311dbaf589d28fb5c9318f8d9e768ee6339d8";
}
