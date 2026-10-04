{
  lib,
  markdownlint-cli2,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "markdownlint-config";
  version = "0.1.0";

  # Only the deployable config and its tests; the Nix glue stays out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./config
      ./tests
    ];
  };

  nativeBuildInputs = [ markdownlint-cli2 ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash tests/run.sh

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share"
    cp -R config "$out/share/markdownlint"

    runHook postInstall
  '';

  meta = {
    description = "markdownlint options file and custom table rule for the VS Code extension";
    platforms = lib.platforms.all;
  };
}
