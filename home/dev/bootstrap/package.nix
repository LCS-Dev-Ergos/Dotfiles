{
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
  zsh,
  nodejs_24,
  nodejs_26,
  python314,
  callPackage,
  coreutils,
  diffutils,
  writeText,
  runtimeManagerBackend ? "native",
}:
let
  platforms = import ./platforms.nix;
  nativeManagers = import ../native-managers.nix;
  system = stdenvNoCC.hostPlatform.system;
  baseline = import ./validate.nix {
    baseline = import ../runtime-baseline.nix;
    inherit system;
    backend = runtimeManagerBackend;
  };
  assets = callPackage ./assets.nix { inherit baseline; };
  policy = import ./policy.nix;
  pythonRuntime = python314.withPackages (packages: [ packages.tkinter ]);
  nixRuntime = name: package: {
    inherit (package) version;
    path = "${package}/bin/${name}";
  };
  manifest = baseline // {
    platform = system;
    backend = runtimeManagerBackend;
    inherit policy;
    setup = nativeManagers.bootstrap.${system} // {
      shell = lib.getExe zsh;
      # Interpolation copies both inputs into the store and records them as
      # manifest references. toString would only name the source path, which
      # garbage collection can remove from under an installed dev-bootstrap.
      shellProbe = "${./probe-shell.zsh}";
      shellConfig = "${../../shells/zsh/config}";
    };
    node = if runtimeManagerBackend == "native" then assets.node else baseline.node;
    python =
      baseline.python
      // lib.optionalAttrs (runtimeManagerBackend == "native") {
        builder = "${assets.pythonBuilder}/bin/python-build";
        definition = assets.pythonDefinition;
        sourceCache = toString assets.pythonCache;
      };
    inherit (baseline) ocaml;
    # Exact versions are checked at runtime; never substitute a nearby release.
    nixRuntimes = lib.optionalAttrs (runtimeManagerBackend == "nixpkgs") {
      "node-${nodejs_24.version}" = nixRuntime "node" nodejs_24;
      "node-${nodejs_26.version}" = nixRuntime "node" nodejs_26;
      "python-${python314.version}" = {
        inherit (python314) version;
        path = "${pythonRuntime}/bin/python3";
        isolated = false;
      };
    };
  };
  manifestFile = writeText "runtime-baseline.json" (builtins.toJSON manifest);
  # The same declaration source checks evaluate, without store assets.
  fixtureManifest = writeText "recovery-test-baseline.json" (
    builtins.toJSON (import ./tests/manifest.nix)
  );
in
assert
  builtins.attrNames nativeManagers.bootstrap == builtins.attrNames platforms
  || throw "development-bootstrap: native setup recipes must cover exactly the supported platforms";
assert
  builtins.all builtins.hasContext [
    manifest.setup.shellProbe
    manifest.setup.shellConfig
  ]
  || throw "development-bootstrap: shell qualification inputs must be store references";
# Force declaration and target validation even when only drvPath is evaluated.
builtins.seq baseline (
  stdenvNoCC.mkDerivation {
    pname = "development-bootstrap";
    version = "0.1.0";
    src = lib.cleanSourceWith {
      src = ./.;
      filter =
        path: type:
        let
          name = baseNameOf path;
        in
        lib.cleanSourceFilter path type
        && name != "__pycache__"
        && name != ".ruff_cache"
        && !(lib.hasSuffix ".pyc" name);
    };
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    doCheck = true;
    doInstallCheck = true;
    checkPhase = ''
      runHook preCheck
      # Shell fixtures run the entry directly; keep bytecode out of the
      # source tree that installPhase copies.
      export PYTHONDONTWRITEBYTECODE=1
      export DEVRESTORE_SOURCE="$PWD/bootstrap.py"
      export DEVRESTORE_PYTHON=${lib.getExe python3}
      export DEVRESTORE_MANIFEST=${fixtureManifest}
      export DEV_BOOTSTRAP_TEST_HELPERS=${../../shells/zsh/config/tests/helpers.zsh}
      export DEV_BOOTSTRAP_TEST_UTILITIES=${
        lib.makeBinPath [
          coreutils
          diffutils
        ]
      }
      export DEV_BOOTSTRAP_TEST_ZSH=${lib.getExe zsh}
      export DEV_BOOTSTRAP_SHELL_CONFIG=${../../shells/zsh/config}
      ${lib.getExe python3} -B tests/run.py package
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/development-bootstrap" "$out/bin"
      # Only the entry and its package; tests never enter the import path.
      cp bootstrap.py "$out/share/development-bootstrap/"
      cp -r core "$out/share/development-bootstrap/"
      cp ${manifestFile} \
        "$out/share/development-bootstrap/baseline.json"
      makeWrapper ${lib.getExe python3} "$out/bin/dev-bootstrap" \
        --add-flags "$out/share/development-bootstrap/bootstrap.py" \
        --add-flags "--manifest $out/share/development-bootstrap/baseline.json" \
        --suffix PATH : ${lib.makeBinPath [ coreutils ]}
      ln -s dev-bootstrap "$out/bin/devrestore"
      runHook postInstall
    '';
    installCheckPhase = ''
      export DEV_BOOTSTRAP_TEST_HELPERS=${../../shells/zsh/config/tests/helpers.zsh}
      export DEV_BOOTSTRAP_TEST_UTILITIES=${
        lib.makeBinPath [
          coreutils
          diffutils
        ]
      }
      ${lib.getExe zsh} tests/bootstrap/test-cli-aliases.zsh "$out"
    '';
    meta = {
      description = "Explicit bootstrap of the shared development baseline";
      mainProgram = "dev-bootstrap";
      platforms = builtins.attrNames platforms;
    };
  }
)
