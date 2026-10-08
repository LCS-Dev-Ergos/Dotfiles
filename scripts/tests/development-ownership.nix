# Evaluate with: nix eval --json --file scripts/tests/development-ownership.nix
let
  language = import ../../home/dev/languages/javascript;
  development = import ../../home/dev;
  inventory = import ../../home/dev/native-managers.nix;
  baseline = import ../../home/dev/runtime-baseline.nix;
  acceptsDeclaration =
    overrides:
    (builtins.tryEval (
      import ../../home/dev/bootstrap/validate.nix ({ inherit baseline; } // overrides)
    )).success;
  withDefaults = overrides: {
    baseline = baseline // {
      defaults = baseline.defaults // overrides;
    };
  };
  # Exercise invalid declarations at the evaluation boundary, independently
  # from the executor's runtime checks.
  rejectedDeclarations = {
    rejectsBootstrapPlatform.system = "aarch64-linux";
    rejectsBootstrapBackend.backend = "unknown";
    rejectsMissingDefault.baseline = baseline // {
      defaults = builtins.removeAttrs baseline.defaults [ "node" ];
    };
    rejectsUndeclaredNodeDefault = withDefaults { node = "0.0.0"; };
    rejectsPythonVersionMismatch = withDefaults { python = "0.0.0"; };
    rejectsUndeclaredOcamlDefault = withDefaults { ocaml = "0.0.0"; };
    rejectsNativeVersionMismatch = withDefaults { rust = "0.0.0"; };
  };
  packageNames =
    backend: ready:
    (language {
      lib.optionals = enabled: values: if enabled then values else [ ];
      pkgs = {
        fnm = "fnm";
        nodejs_24 = "node";
      };
      runtimeManagerBackend = backend;
      nativeFnmReady = ready;
    }).home.packages;
  valid =
    backend: ready:
    builtins.all (entry: entry.assertion)
      (development {
        pkgs.callPackage = _: _: "development-recovery";
        runtimeManagerBackend = backend;
        nativeFnmReady = ready;
      }).assertions;
  checks = {
    supportedBootstrapDeclarations = builtins.all acceptsDeclaration [
      {
        system = "aarch64-darwin";
        backend = "native";
      }
      {
        system = "x86_64-linux";
        backend = "native";
      }
      {
        system = "x86_64-linux";
        backend = "nixpkgs";
      }
    ];
    transitionalNative =
      packageNames "native" false == [
        "node"
        "fnm"
      ];
    completedNative = packageNames "native" true == [ "node" ];
    nixosAdapter =
      packageNames "nixpkgs" false == [
        "node"
        "fnm"
      ];
    validNative = valid "native" true;
    validNixpkgs = valid "nixpkgs" false;
    rejectsUnknownBackend = !(valid "linux" false);
    rejectsNonBooleanCheckpoint = !(valid "native" "yes");
    nativeMacFnm = builtins.elem "fnm" inventory.homebrew;
    archFnmIsNative = inventory.arch.fnm.method == "pacman";
    archFnmPackageDeclared = builtins.elem "fnm" inventory.arch.packages;
  }
  // builtins.mapAttrs (_: declaration: !(acceptsDeclaration declaration)) rejectedDeclarations;
in
assert builtins.all (value: value) (builtins.attrValues checks);
checks
