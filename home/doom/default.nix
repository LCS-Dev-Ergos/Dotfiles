{
  config,
  lib,
  pkgs,
  ...
}:
let
  doomCustomDirectory = "${config.xdg.stateHome}/doom";
  doomCustomState = "${doomCustomDirectory}/custom.el";

  # Doom still integrates the retired Nose 1 runner, but current nixpkgs
  # removed it after years without upstream maintenance. Keep those commands
  # useful with a narrow Nose 2 adapter instead of resurrecting an unsafe,
  # extensively patched Python package. Nose 2 has no failed-test replay;
  # that legacy flag falls back explicitly to a full run.
  nosetestsCompat = pkgs.writeShellApplication {
    name = "nosetests";
    runtimeInputs = [ pkgs.python3Packages.nose2 ];
    text = ''
      translated=()
      while (( $# > 0 )); do
        case "$1" in
          --pdb)
            translated+=(--debugger)
            ;;
          --failed)
            printf '%s\n' \
              'nosetests compatibility: nose2 cannot replay failures; running the full suite.' \
              >&2
            ;;
          -w|--where)
            if (( $# < 2 )); then
              printf '%s\n' "nosetests compatibility: $1 requires a directory" >&2
              exit 64
            fi
            translated+=(--start-dir "$2")
            shift
            ;;
          --where=*)
            translated+=(--start-dir "''${1#*=}")
            ;;
          *)
            translated+=("$1")
            ;;
        esac
        shift
      done

      exec nose2 "''${translated[@]}"
    '';
  };
in
{
  # Executables required by the enabled Doom modules. Co-locating them with
  # the module declaration keeps the editor feature set reproducible on both
  # hosts and prevents ambient Homebrew/host packages from masking omissions.
  home.packages = [
    pkgs.black
    pkgs.csharpier
    pkgs.dockfmt
    pkgs.glslang
    pkgs.gomodifytags
    pkgs.gore
    pkgs.gotests
    pkgs.isync
    pkgs.ktlint
    pkgs.mu
    pkgs.ocamlPackages.merlin
    pkgs.ocamlPackages.utop
    pkgs.pipenv
    pkgs.sbcl
    pkgs.shfmt
    pkgs.zig
    nosetestsCompat
  ];

  # Emacs Customize owns custom.el and may rewrite it at runtime. Preserve the
  # reviewed snapshot as a one-time private seed, then let Emacs maintain state
  # outside the immutable Doom source. Activation never overwrites an existing
  # state file, so interactive choices survive switches and rollbacks.
  home.activation.seedDoomCustom = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m 0700 \
      ${lib.escapeShellArg doomCustomDirectory}
    if [[ ! -e ${lib.escapeShellArg doomCustomState} ]]; then
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0600 \
        ${lib.escapeShellArg (toString ./custom.el)} \
        ${lib.escapeShellArg doomCustomState}
    fi
  '';

  # Package downloads, compiled Lisp, caches, and session data already live in
  # Doom's own data/cache tree. With custom.el redirected, the declarative Lisp
  # directory has no legitimate runtime writer and can follow Nix generations.
  xdg.configFile."doom".source = ./doom;
}
