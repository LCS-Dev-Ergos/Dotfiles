{
  lib,
  makeWrapper,
  markdownlint-cli2,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "markdownlint-config";
  version = "0.3.0";

  # Only the deployable files and their tests; the Nix glue stays out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./config
      ./tests
      ./mdlint.sh
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    markdownlint-cli2
  ];

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

    mkdir -p "$out/share" "$out/libexec" "$out/bin"
    cp -R config "$out/share/markdownlint"
    install -m 0755 mdlint.sh "$out/libexec/mdlint.sh"

    # mdlint finds its rule files in the same store path, whatever the user configuration
    # says, and brings the linter it calls.
    makeWrapper "$out/libexec/mdlint.sh" "$out/bin/mdlint" \
      --set MDLINT_CONFIG_DIR "$out/share/markdownlint" \
      --prefix PATH : ${lib.makeBinPath [ markdownlint-cli2 ]}

    runHook postInstall
  '';

  meta = {
    description = "markdownlint rule sets with a custom table rule and the mdlint command";
    platforms = lib.platforms.all;
  };
}
