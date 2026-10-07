"""Keep registered opam inputs alive beyond their originating generation."""

import os
from pathlib import Path
from support import BootstrapError, run, writable_directory


def retain_opam_source(recovery):
    """Called under the apply lock, never during plan or verification.

    opam retains the unselected frozen registration after handing switches to
    the live repository. Its URL must continue working for `opam update --all`.
    A GC root preserves that URL without rewriting any repository selection.
    Roots are deliberately not retired automatically: other switches may use
    them, and ordinary opam processes do not participate in our apply lock.
    """
    if recovery.data["backend"] != "native" or "ocaml" not in recovery.only:
        return
    declaration = recovery.data["ocaml"]
    command = declaration.get("retainCommand")
    if not command:
        # Standalone fixture/legacy manifests do not declare Nix retention.
        return
    source = Path(declaration["source"])
    if source.parent != Path("/nix/store") or not (source / "repo").is_file():
        raise BootstrapError("Cannot retain the declared opam store input")
    directory = recovery.state / "opam-sources"
    writable_directory(directory)
    root = directory / source.name
    if os.path.lexists(root) and (
        not root.is_symlink() or root.resolve() != source
    ):
        raise BootstrapError(f"Conflicting opam source GC root: {root}")
    run(
        [
            command,
            "--realise",
            str(source),
            "--add-root",
            str(root),
            "--indirect",
        ],
        cwd=str(recovery.state),
    )
    if not root.is_symlink() or root.resolve() != source:
        raise BootstrapError("Nix did not create the opam source GC root")
