{
  sketchybar,
  lib,
  python3,
}:
assert lib.assertMsg (
  sketchybar.version == "2.24.0"
) "Revalidate or retire the SketchyBar screen-unlock patch after an upstream update.";
sketchybar.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./unlock.patch ];
  nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ python3 ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 ${./tests/unlock_test.py} src/event.c
    runHook postCheck
  '';
})
