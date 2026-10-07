"""OCaml through opam: frozen repository creation, checkpointing and handover."""

import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import NIX_STORE, read_json_object, writable_directory
from .base import SELECTION_NAME, Adapter


class OcamlAdapter(Adapter):
    language = "ocaml"
    manager_name = "opam"
    compiles = True
    pending_reason = "Repository handover pending; apply resumes owned work"

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

    # Frozen repository -------------------------------------------------------

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

    def repositories(self, *scope):
        return self.run(
            *self.context.arguments("opamList"), *scope
        ).splitlines()

    def qualify_repository(self, name, expected_url):
        """Validate a pending frozen registration without updating its source."""
        report = self.run(*self.context.arguments("opamListAll"))
        for line in report.splitlines():
            fields = line.split()
            if fields and fields[0] == name:
                if len(fields) >= 2 and fields[1] == expected_url:
                    return
                break
        raise BootstrapError(
            "Pending repository address changed; refusing handover"
        )

    def pending_path(self, row):
        identity = hashlib.sha256(str(self.root).encode()).hexdigest()
        return self.context.state / f"opam-{identity}-{row['version']}.json"

    def save_pending(self, path, data):
        # Atomic checkpoints survive interruption without accepting partial JSON.
        with tempfile.NamedTemporaryFile(
            dir=self.context.state, mode="w", delete=False
        ) as file:
            temporary = Path(file.name)
            try:
                json.dump(data, file)
                file.flush()
                os.fsync(file.fileno())
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)

    def read_pending(self, row):
        path = self.pending_path(row)
        if not os.path.lexists(path):
            return None
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise BootstrapError(
                "Pending opam state must be a private regular file"
            )
        data = read_json_object(path)
        if (
            data.get("root") != str(self.root)
            or data.get("version") != row["version"]
            or data.get("revision") != self.context.data["ocaml"]["revision"]
            or data.get("stage") not in ("create", "handover")
            or not isinstance(data.get("fresh"), bool)
        ):
            raise BootstrapError(
                "Pending opam state does not match this baseline/root"
            )
        return data

    def pending(self, row):
        return self.read_pending(row) is not None

    def before_apply(self):
        """Keep the registered frozen repository alive beyond its generation.

        opam retains the unselected frozen registration after handing switches
        to the live repository. Its URL must keep working for `opam update
        --all`; a GC root preserves it without rewriting any selection. Roots
        are not retired automatically: other switches may use them, and
        ordinary opam processes do not participate in our apply lock.
        """
        declaration = self.context.data["ocaml"]
        command = declaration.get("retainCommand")
        if self.context.backend != "native" or not command:
            # Only the packaged manifest declares Nix retention; fixtures do not.
            return
        source = Path(declaration["source"])
        if source.parent != NIX_STORE or not (source / "repo").is_file():
            raise BootstrapError("Cannot retain the declared opam store input")
        directory = self.context.state / "opam-sources"
        writable_directory(directory)
        root = directory / source.name
        if os.path.lexists(root) and (
            not root.is_symlink() or root.resolve() != source
        ):
            raise BootstrapError(f"Conflicting opam source GC root: {root}")
        process.run(
            [
                command,
                "--realise",
                str(source),
                "--add-root",
                str(root),
                "--indirect",
            ],
            cwd=str(self.context.state),
        )
        if not root.is_symlink() or root.resolve() != source:
            raise BootstrapError("Nix did not create the opam source GC root")

    def install(self, row):
        repository = Path(self.context.data["ocaml"]["source"])
        if not repository.is_absolute() or not (repository / "repo").is_file():
            raise BootstrapError("Missing immutable opam repository input")
        writable_directory(self.root)
        self.create(row, repository)

    def create(self, row, repository):
        declaration = self.context.data["ocaml"]
        policy = self.context.data["policy"]
        name = policy["repositoryName"]
        upstream = policy["upstreamName"]
        url = repository.as_uri()
        switch = self.switch(row["version"])
        path = self.pending_path(row)
        pending = self.read_pending(row)
        if pending is None:
            pending = {
                "root": str(self.root),
                "version": row["version"],
                "revision": declaration["revision"],
                "stage": "create",
                "fresh": not (self.root / "config").exists(),
            }
            self.save_pending(path, pending)
        if not (self.root / "config").exists():
            if not pending["fresh"] or pending["stage"] != "create":
                raise BootstrapError(
                    "Pending opam root disappeared; inspect it manually"
                )
            self.run(
                *self.context.arguments("opamInit", name=name, url=url),
                timeout=policy["timeouts"]["repository"],
            )
        if pending["fresh"]:
            defaults = self.repositories("--set-default")
            if defaults not in ([name], [upstream]):
                raise BootstrapError(
                    "Pending root defaults changed; inspect it manually"
                )
            if defaults == [name]:
                self.qualify_repository(name, url)
        # opam rejects an existing registration with a conflicting address.
        # Do not change any existing switch or repository-default selection.
        target = self.root / switch
        if not target.exists():
            if pending["stage"] != "create":
                raise BootstrapError(
                    "Pending switch disappeared; inspect it manually"
                )
            self.run(
                *self.context.arguments("opamRegister", name=name, url=url),
                timeout=policy["timeouts"]["repository"],
            )
            self.run(
                *self.context.arguments(
                    "opamCreate",
                    switch=switch,
                    version=row["version"],
                    name=name,
                ),
                timeout=policy["timeouts"]["ocaml"],
                env=self.recipe.get("buildEnvironment", {}),
                source_build=True,
            )
        self.verify(row)
        selected = self.repositories(f"--switch={switch}")
        if selected not in ([name], [upstream]):
            raise BootstrapError(
                "Pending switch repositories changed; refusing handover"
            )
        if selected == [name]:
            self.qualify_repository(name, url)
        pending["stage"] = "handover"
        self.save_pending(path, pending)
        self.run(
            *self.context.arguments(
                "opamRegister", name=upstream, url=policy["upstreamUrl"]
            ),
            timeout=policy["timeouts"]["repository"],
        )
        if selected == [name]:
            self.run(
                *self.context.arguments(
                    "opamSelectSwitch", name=upstream, switch=switch
                )
            )
        if pending["fresh"]:
            defaults = self.repositories("--set-default")
            if defaults not in ([name], [upstream]):
                raise BootstrapError(
                    "Pending root repository defaults changed; refusing overwrite"
                )
            if defaults == [name]:
                self.run(
                    *self.context.arguments("opamSelectDefault", name=upstream)
                )
        # Retain the unselected frozen registration. opam provides no atomic
        # compare-and-unregister command; --all-switches could change a switch
        # selected by an ordinary manager after a separate reference query.
        path.unlink()
