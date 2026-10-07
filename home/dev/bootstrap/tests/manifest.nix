# Declared baseline and argv policy without store assets: the manifest that
# orchestration fixtures run against. Evaluates offline from this checkout.
let
  baseline = import ../validate.nix { baseline = import ../../runtime-baseline.nix; };
in
baseline // { policy = import ../policy.nix; }
