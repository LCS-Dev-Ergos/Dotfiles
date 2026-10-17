{
  callPackage,
  gum,
  lib,
  makeWrapper,
  procps,
  python3,
  stdenvNoCC,
}:
let
  python = lib.fileset.fileFilter (file: file.hasExt "py");
  # The report is drawn in the terminal style every shell tool shares.
  terminalStyle = callPackage ../../../shells/terminal-style/package.nix { };
  # Gum asks for confirmation on a styled terminal, ps finds running editions;
  # both are appended, so the user's own copies still come first.
  runtimePath = [ gum ] ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ procps ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "vscode-sync";
  version = "1.0.0";

  # Only the Python sources; the Nix glue, the README and any bytecode stay
  # out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./vscode_sync.py
      (python ./core)
      (python ./tests)
    ];
  };

  # The package reads this copy; a repository checkout reads the module.
  postPatch = ''
    install -m 0644 ${terminalStyle}/share/terminal-style/terminal_style.py .
  '';

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

    # Only the entry, its package and the style; tests never enter the
    # import path.
    share="$out/share/vscode-sync"
    mkdir -p "$share"
    cp vscode_sync.py terminal_style.py "$share/"
    cp -r core "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python3} -I -m compileall -q "$share/core" "$share/terminal_style.py"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tool's imports.
    makeWrapper ${lib.getExe python3} "$out/bin/vscode-sync" \
      --add-flags "-I $share/vscode_sync.py" \
      --suffix PATH : ${lib.makeBinPath runtimePath}

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree.
    "$out/bin/vscode-sync" --version | grep -Fx "vscode-sync ${finalAttrs.version}"

    runHook postInstallCheck
  '';

  meta = {
    description = "Share VS Code Stable's extensions and user files with VS Code Insiders";
    mainProgram = "vscode-sync";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
