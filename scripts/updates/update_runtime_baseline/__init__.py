"""Report or advance the exact upstream releases the runtime baseline pins.

Compares home/dev/runtime-baseline.nix and the release assets, installer
scripts and recorded licenses in home/dev/native-managers.nix with their
official upstreams.
Findings are classified:

  update   a newer patch release in the declared line, or the newest stable
           release of a tool without maintenance lines, installable on both
           platforms through its manager;
  pending  upstream has it, but the manager cannot install it yet (no
           python-build or ruby-build definition in the latest release, no
           SDKMAN candidate, a missing platform asset);
  line     a newer line (a new major, or minor where lines are maintained);
  drift    an installer script's bytes, or a recorded license's text, no
           longer match the pinned hash.

Only update and drift are actionable. --apply rewrites update findings, and
line findings of the ecosystems named with --line, by exact replacement, and
lists each replaced release under `retired`; every source resolves first,
the rewritten files are re-evaluated, and both files are restored if
anything but the intended values changed. Drifted installer bytes and
license texts are saved for review; --accept-installer and --accept-license
record the hash of what was reviewed, and refuse if upstream changed again.
The updater never builds, stages, commits or switches.

Modules: `versions` (release arithmetic), `model` (findings, edits and
classification), `upstream` (bounded HTTPS), `declarations` (Nix evaluation
and checked rewrites), `resolvers` (one entry per ecosystem, mostly
declarative tracks), `report` and `cli`.
"""
