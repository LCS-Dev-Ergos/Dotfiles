"""OCaml through opam: one switch per declared compiler, from opam's upstream."""

import os
import re
import tempfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import writable_directory
from .base import SELECTION_NAME, Adapter


class OcamlAdapter(Adapter):
    language = "ocaml"
    manager_name = "opam"
    compiles = True

    def resolve_roots(self):
        return {"OPAMROOT": self.locate("OPAMROOT", Path.home() / ".opam")}

    def manager_candidates(self):
        if not self.recipe:
            return None
        directory = Path(self.recipe["managerDirectory"])
        return [directory / self.recipe["managers"]["ocaml"]]

    def readiness(self):
        self.check_manager_release()

    def switch(self, version):
        return f"lcs-ocaml-{version}"

    def baseline(self):
        return [
            self.row(release, self.root / self.switch(release) / "bin/ocamlc")
            for release in self.context.data["ocaml"]["versions"]
        ]

    def identity(self, row, path):
        return process.run([str(path), "-version"])

    def canary(self, row, path, *, complete):
        with tempfile.TemporaryDirectory(
            prefix="devrestore-ocaml-"
        ) as temporary:
            work = Path(temporary)
            source = work / "hello.ml"
            source.write_text('print_endline "recovery-ok";;\n')
            process.run([str(path), "-o", str(work / "hello"), str(source)])
            output = process.run(
                [str(path.parent / "ocamlrun"), str(work / "hello")]
            )
            if output != "recovery-ok":
                raise BootstrapError("OCaml compile/run canary failed")

    def selection(self):
        config = self.root / "config"
        if not config.is_file():
            return None
        match = re.search(
            r'^switch:\s*"([^"\n]+)"', config.read_text()[:65536], re.MULTILINE
        )
        return match.group(1) if match else None

    def installed(self):
        if not self.root.is_dir():
            return []
        return sorted(
            path.name
            for path in self.root.iterdir()
            if path.is_dir()
            and not path.name.startswith(".")
            and (path / ".opam-switch").is_dir()
        )

    def selected_runtime(self):
        selection = self.selection()
        if not selection:
            raise BootstrapError("No global opam switch selected")
        if Path(selection).is_absolute():
            return Path(selection) / "_opam/bin/ocamlc"
        if re.fullmatch(SELECTION_NAME, selection):
            return self.root / selection / "bin/ocamlc"
        raise BootstrapError("Unsupported opam global switch identity")

    def initialize_default(self):
        if self.selection() is not None:
            return
        config = self.root / "config"
        if config.is_file() and re.search(
            r"^switch:", config.read_text(), re.MULTILINE
        ):
            raise BootstrapError("Inspect the existing opam global selection")
        self.run(
            *self.context.arguments(
                "opamDefault",
                switch=self.switch(self.context.data["defaults"]["ocaml"]),
            )
        )

    def repair_hooks(self):
        hook = self.root / "opam-init/env_hook.zsh"
        if not hook.is_file():
            self.run(*self.context.arguments("opamHooks"))
        if not hook.is_file():
            raise BootstrapError("opam did not create the requested Zsh hook")

    def run(self, *arguments, timeout=30, env=None, source_build=False):
        return process.run(
            [
                str(self.manager()),
                *arguments,
                *self.context.arguments("opamCommon", root=str(self.root)),
            ],
            timeout=timeout,
            env=env,
            source_build=source_build,
            cwd=self.context.state,
        )

    def install(self, row):
        """Create the declared switch from the root's own repositories.

        A fresh bare root registers opam's default upstream and its Zsh
        hooks, without writing shell configuration or selecting a global
        switch. Existing roots keep their repositories and selections.
        """
        timeouts = self.context.data["policy"]["timeouts"]
        writable_directory(self.root)
        if not (self.root / "config").exists():
            self.run(
                *self.context.arguments("opamInit"),
                timeout=timeouts["repository"],
            )
        switch = self.switch(row["version"])
        # Planning saw no switch; one appearing since then belongs to someone
        # else, and an interrupted creation stays for manual inspection.
        if os.path.lexists(self.root / switch):
            raise BootstrapError("opam switch appeared; refusing overwrite")
        self.run(
            *self.context.arguments(
                "opamCreate", switch=switch, version=row["version"]
            ),
            timeout=timeouts["ocaml"],
            env=self.recipe.get("buildEnvironment", {}),
            source_build=True,
        )
