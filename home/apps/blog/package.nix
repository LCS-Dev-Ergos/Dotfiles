{
  callPackage,
  git,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
let
  sources = lib.fileset.fileFilter (file: file.hasExt "py");
  # Only the standard library: Git and Hugo come from the caller's PATH,
  # where Home Manager installs Git and the shell's dependency manifest Hugo.
  # The output is drawn in the terminal style every shell tool shares.
  terminalStyle = callPackage ../../shells/terminal-style/package.nix { };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "blog";
  version = "1.0.0";

  # Only the Python sources; the Nix glue, the README and any bytecode stay
  # out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./blog.py
      (sources ./core)
      (sources ./tests)
    ];
  };

  # The package reads this copy; a repository checkout reads the module.
  postPatch = ''
    install -m 0644 ${terminalStyle}/share/terminal-style/terminal_style.py .
  '';

  nativeBuildInputs = [ makeWrapper ];
  # The tests drive a real Git against repositories they create.
  nativeCheckInputs = [ git ];
  # stdenv's bash can crash in fixupPhase on Darwin without a locale, which
  # cuts the build-directory audit short without failing the build.
  env.LC_ALL = "C";

  dontBuild = true;
  doCheck = true;
  doInstallCheck = true;

  checkPhase = ''
    runHook preCheck

    # The tests build their own vault, repository and remote, and fake
    # Hugo. -B keeps bytecode out of core/, which installPhase copies.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe python3} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    share="$out/share/blog"
    mkdir -p "$share"
    cp blog.py terminal_style.py "$share/"
    cp -r core "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python3} -I -m compileall -q "$share/core" "$share/terminal_style.py"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tool's imports.
    makeWrapper ${lib.getExe python3} "$out/bin/blog" \
      --add-flags "-I $share/blog.py"

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree, and a missing
    # configuration must be reported, not raised, from the installed layout.
    "$out/bin/blog" --version | grep -Fx "blog ${finalAttrs.version}"
    status=0
    "$out/bin/blog" status --config missing.toml 2> error.txt || status=$?
    test "$status" -eq 1
    grep -F "No configuration at missing.toml" error.txt

    runHook postInstallCheck
  '';

  meta = {
    description = "Publish a Hugo blog written in an Obsidian vault";
    mainProgram = "blog";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
