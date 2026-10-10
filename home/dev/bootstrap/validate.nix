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
  # `retired` mirrors the declarations: every list sits at the path of a
  # declared value and holds releases that path no longer declares.
  retired =
    let
      walk =
        path: value:
        if builtins.isList value then
          [ { inherit path value; } ]
        else
          builtins.concatMap (name: walk (path ++ [ name ]) value.${name}) (builtins.attrNames value);
    in
    walk [ ] (baseline.retired or { });
  declaredAt = builtins.foldl' (
    value: name: if builtins.isAttrs value && value ? ${name} then value.${name} else null
  ) baseline;
  releasesAt =
    path:
    let
      value = declaredAt path;
    in
    if builtins.isList value then value else [ value ];
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
assert require (builtins.all (
  entry:
  builtins.elem (builtins.head entry.path) [
    "nativeToolchains"
    "node"
    "ocaml"
    "python"
  ]
  && builtins.isString (builtins.head (releasesAt entry.path))
) retired) "retired releases must sit at a declared release's path";
assert require (builtins.all (
  entry: builtins.all (release: !builtins.elem release (releasesAt entry.path)) entry.value
) retired) "a retired release is declared again";
baseline
