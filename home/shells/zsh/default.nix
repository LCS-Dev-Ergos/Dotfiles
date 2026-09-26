{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Keep the complete Zsh unit in one store path. Validation and dependency
  # tooling intentionally navigate from config/ to sibling packages and root
  # files; separate path copies would sever those read-only relationships.
  zshSource = ./.;

  shdoc = pkgs.callPackage ./shdoc.nix { };

  # packages/zsh-dependencies.tsv names, per dependency, the Home Manager
  # package that supplies it on a flake-managed host ("-" when another owner
  # does: nix-darwin, a runtime manager, Homebrew, or the distribution).
  # zshdeps reads that column for its install hints, so we check it against
  # what this configuration really installs; a rename or a package moving
  # between owners then fails the build instead of leaving a stale hint.
  # "a|b" names alternatives, one per host where the owner differs (the
  # Darwin C/C++ drivers replace the stock compiler wrappers); any one of
  # them being installed satisfies the row.
  registryRows = builtins.filter (line: line != "" && !lib.hasPrefix "#" line) (
    lib.splitString "\n" (builtins.readFile ./packages/zsh-dependencies.tsv)
  );
  registryNixNames = lib.filter (name: name != "-") (
    map (row: builtins.elemAt (lib.splitString "\t" row) 5) registryRows
  );
  installedNames = map lib.getName config.home.packages;
  unownedNames = lib.filter (
    spec: !lib.any (name: builtins.elem name installedNames) (lib.splitString "|" spec)
  ) registryNixNames;
in
{
  # Keep file placement independent from programs.zsh. On Darwin, nix-darwin
  # owns the login-shell binary through users.users.<name>.shell
  # (hosts/lcs-macbook-pro/darwin.nix); standalone Home Manager installs the
  # package on Linux.
  #
  # The custom config guards against double compinit (20-zinit.zsh runs it;
  # 85-completions.zsh checks whether initialization already happened).
  # Not using programs.zsh's own options at all means Home Manager never
  # generates a second compinit call to conflict with that.
  #
  # All shell source is store-backed. Runtime-generated completion dumps, lazy
  # loaders, path data, and traces already live below XDG cache/state paths;
  # source-adjacent .zwc compilation was retired because its small startup gain
  # did not justify a writable configuration tree or rollback-incompatible
  # bytecode. Durable edits now require a switch and follow Nix generations.
  home = {
    # The documentation toolchain is required by the catalog, completion
    # generation, and the test suite, and nothing else on the machine uses it,
    # so this module owns it. Shared tools (git, gum, fzf, ...) stay with the
    # modules that configure them; the assertion below keeps the registry
    # honest about who that is.
    packages = [
      pkgs.gawk
      shdoc
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.zsh ];

    file = {
      ".zshenv".source = "${zshSource}/zshenv-bootstrap";
      ".zprofile".source = "${zshSource}/zprofile";
      ".zshrc".source = "${zshSource}/zshrc";
      ".p10k.zsh".source = "${zshSource}/p10k.zsh";
    };
  };

  xdg.configFile."zsh".source = "${zshSource}/config";

  assertions = [
    {
      assertion = unownedNames == [ ];
      message =
        "home/shells/zsh/packages/zsh-dependencies.tsv expects these Home Manager "
        + "packages, but no module installs them: "
        + lib.concatStringsSep ", " unownedNames
        + ". Install them, or set their nix column to \"-\".";
    }
  ];
}
