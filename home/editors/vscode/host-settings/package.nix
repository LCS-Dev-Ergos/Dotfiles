{
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
let
  python = lib.fileset.fileFilter (file: file.hasExt "py");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "vscode-host-settings";
  version = "1.0.0";

  # Only the Python sources; the Nix glue and any bytecode stay out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./vscode_host_settings.py
      (python ./core)
      (python ./tests)
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  # stdenv's bash can crash in fixupPhase on Darwin without a locale, which
  # cuts the build-directory audit short without failing the build.
  env.LC_ALL = "C";

  dontBuild = true;
  doCheck = true;
  doInstallCheck = true;

  checkPhase = ''
    runHook preCheck

    # The tests build their own homes; none of them may reach the real one.
    # -B keeps bytecode out of core/, which installPhase copies.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe python3} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    # Only the entry and its package; tests never enter the import path.
    share="$out/share/vscode-host-settings"
    mkdir -p "$share"
    cp vscode_host_settings.py "$share/"
    cp -r core "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python3} -I -m compileall -q "$share/core"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tool's imports.
    makeWrapper ${lib.getExe python3} "$out/bin/vscode-host-settings" \
      --add-flags "-I $share/vscode_host_settings.py"

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree.
    "$out/bin/vscode-host-settings" --version \
      | grep -Fx "vscode-host-settings ${finalAttrs.version}"

    runHook postInstallCheck
  '';

  meta = {
    description = "Resolve the host-bound paths of VS Code's settings.json for this machine";
    mainProgram = "vscode-host-settings";
    platforms = lib.platforms.all;
  };
})
