{
  callPackage,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
let
  sources = lib.fileset.fileFilter (file: file.hasExt "py");
  # pikepdf (libqpdf) does the PDF work in-process. Ghostscript, for lossy
  # compression, and ddjvu, for DjVu, come from the caller's PATH, where the
  # shell's dependency manifest installs them.
  python = python3.withPackages (ps: [ ps.pikepdf ]);
  # The output is drawn in the terminal style every shell tool shares.
  terminalStyle = callPackage ../../shells/terminal-style/package.nix { };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pdf-tools";
  version = "1.0.0";

  # Only the Python sources; the Nix glue, the README and any bytecode stay
  # out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pdf_tools.py
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

    # The tests build their own PDFs and fake Ghostscript and ddjvu. -B
    # keeps bytecode out of core/, which installPhase copies.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe python} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    share="$out/share/pdf-tools"
    mkdir -p "$share"
    cp pdf_tools.py terminal_style.py "$share/"
    cp -r core "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python} -I -m compileall -q "$share/core" "$share/terminal_style.py"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tool's imports.
    makeWrapper ${lib.getExe python} "$out/bin/pdf-tools" \
      --add-flags "-I $share/pdf_tools.py"

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree, and pikepdf must
    # load from the installed layout.
    "$out/bin/pdf-tools" --version | grep -Fx "pdf-tools ${finalAttrs.version}"
    ${lib.getExe python} -I -c 'import pikepdf; p = pikepdf.new(); p.add_blank_page(); p.save("sample.pdf")'
    "$out/bin/pdf-tools" info sample.pdf | grep -F "Pages"

    runHook postInstallCheck
  '';

  meta = {
    description = "Inspect, edit, compress, protect and clean PDF documents";
    mainProgram = "pdf-tools";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
