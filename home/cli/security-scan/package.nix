{
  callPackage,
  clamav,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
let
  sources = lib.fileset.fileFilter (file: file.hasExt "py");
  # pikepdf reads PDFs for the structural layer and yara-python runs the
  # YARA layer in-process; ClamAV's clamscan runs the third layer, against
  # the signatures the Home Manager module keeps current.
  python = python3.withPackages (ps: [
    ps.pikepdf
    ps.yara-python
  ]);
  # The report is drawn in the terminal style every shell tool shares.
  terminalStyle = callPackage ../../shells/terminal-style/package.nix { };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "security-scan";
  version = "2.0.0";

  # Only the Python sources and the rules; the Nix glue, the README and any
  # bytecode stay out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./security_scan.py
      ./rules
      (sources ./core)
      (sources ./tests)
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

    # The tests write their own samples and a fake clamscan; none of them
    # may reach a real ClamAV. -B keeps bytecode out of core/, which
    # installPhase copies.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe python} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    share="$out/share/security-scan"
    mkdir -p "$share"
    cp security_scan.py terminal_style.py "$share/"
    cp -r core rules "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python} -I -m compileall -q "$share/core" "$share/terminal_style.py"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tool's imports. The bundled clamscan comes first on its PATH.
    makeWrapper ${lib.getExe python} "$out/bin/security-scan" \
      --add-flags "-I $share/security_scan.py" \
      --prefix PATH : ${lib.makeBinPath [ clamav ]}
    # The short name the Zsh implementation had.
    ln -s security-scan "$out/bin/secscan"

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree, and the bundled
    # rules and clamscan must work from the installed layout; with no
    # signatures in the sandbox, ClamAV only reports itself unavailable.
    "$out/bin/security-scan" --version | grep -Fx "security-scan ${finalAttrs.version}"
    echo clean > "$TMPDIR/sample.txt"
    PATH= "$out/bin/security-scan" --quiet "$TMPDIR/sample.txt"

    runHook postInstallCheck
  '';

  meta = {
    description = "Scan files and folders for hidden threats with structural checks, YARA and ClamAV";
    mainProgram = "security-scan";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
