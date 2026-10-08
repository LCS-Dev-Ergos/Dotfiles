# Fail during evaluation before composing assets or an executable manifest.
{
  baseline,
  system ? null,
  backend ? null,
}:
let
  platforms = import ./platforms.nix;
  nativeNames = builtins.attrNames baseline.nativeToolchains;
  requiredDefaults = [
    "node"
    "ocaml"
    "python"
  ]
  ++ nativeNames;
  require = condition: message: condition || throw "development-bootstrap: ${message}";
in
assert require (
  system == null || builtins.elem system platforms
) "unsupported platform ${toString system}";
assert require (
  backend == null
  || builtins.elem backend [
    "native"
    "nixpkgs"
  ]
) "unsupported runtime backend ${toString backend}";
assert require (
  builtins.attrNames baseline.defaults == builtins.sort builtins.lessThan requiredDefaults
) "defaults must cover exactly the declared toolchains";
assert require (builtins.elem baseline.defaults.node baseline.node.versions)
  "Node default is absent from the baseline";
assert require (
  baseline.defaults.python == baseline.python.version
) "Python default and declared version disagree";
assert require (builtins.elem baseline.defaults.ocaml baseline.ocaml.versions)
  "OCaml default is absent from the baseline";
assert require (builtins.all (
  name: baseline.defaults.${name} == baseline.nativeToolchains.${name}.version
) nativeNames) "native toolchain defaults and versions disagree";
baseline
