# Bootstrap Tests

The fixture suites preserve the existing behavioral coverage while separating
component contracts, collaboration between components, and executable entry
points. Native managers, downloads and installations are substituted in all
automatic checks.

| Category | Coverage |
| --- | --- |
| `unit/` | Manifest input validation and CLI diagnostics; frozen opam source retention, registration failures and ownership conflicts. |
| `integration/` | Native toolchain filesystem transitions, setup orchestration, child environments and shell adapters. |
| `bootstrap/` | Pre-Nix foundation entry, runtime CLI recovery and installed command aliases. |
| `qualification/` | Manual checks against real native managers in disposable roots; excluded from automatic discovery. |

`qualification/native-assets.zsh` installs the packaged Node archives and
builds CPython with real FNM and pyenv. `qualification/native-opam.zsh` drives
real opam through switch creation, interrupted handover, selection
preservation, hook repair and an upstream update, with empty switches instead
of compiler builds. They are the evidence that native managers accept the
generated commands; fixtures cannot provide it. They need network access and
minutes, so they stay outside the fast suites.

Run the source checks from the repository root. Setup contracts evaluate the
declared policy from `tests/manifest.nix` with Nix, without building assets:

```sh
python3 -B home/dev/bootstrap/tests/run.py source
```

The package phase requires the generated baseline manifest and also runs the
runtime CLI and shell fixture scripts. Nix supplies its hermetic interpreter,
Zsh, shell configuration and helper paths through the existing test environment:

```sh
python3 -B home/dev/bootstrap/tests/run.py package --manifest /path/to/baseline.json
```

Either phase accepts `--category unit`, `--category integration` or
`--category bootstrap`. Python cases use standard `unittest` discovery. The
package phase passes the generated manifest; the source phase fails rather
than skipping when Nix cannot evaluate the declaration. The pre-Nix entry
reports a skip inside the isolated package source, where repository scripts
are unavailable.
The installed executable alias check runs separately during `installCheck`:

```sh
zsh home/dev/bootstrap/tests/bootstrap/test-cli-aliases.zsh /path/to/package
```

`scripts/ci-development-bootstrap.sh source` delegates to the same Python
runner. Its `package` phase evaluates ownership and builds the package with
`check` and `installCheck` enabled. Neither phase establishes clean-host,
deployed-shell or real native installation acceptance.
