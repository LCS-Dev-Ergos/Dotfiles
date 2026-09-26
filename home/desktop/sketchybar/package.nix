{
  sketchybar,
  lib,
  python3,
}:
assert lib.assertMsg (
  sketchybar.version == "2.24.0"
) "Revalidate or retire the SketchyBar native patches after an upstream update.";
sketchybar.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./display-reconcile.patch
    ./window-order.patch
  ];
  nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ python3 ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 ${./tests/display_reconcile_test.py} src
    runHook postCheck
  '';
})
