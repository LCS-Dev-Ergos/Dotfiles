"""Frozen opam repository creation, checkpointing and upstream handover."""

import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from support import BootstrapError, run, writable_directory, read_json_object


class OcamlBootstrap:
    def __init__(self, context):
        self.context = context

    def install(self, row):
        repository = Path(self.context.data["ocaml"]["source"])
        if not repository.is_absolute() or not (repository / "repo").is_file():
            raise BootstrapError("Missing immutable opam repository input")
        writable_directory(self.context.opam)
        self.create(row, repository)

    def run(self, *arguments, timeout=30, env=None, source_build=False):
        return run(
            [
                str(self.context.manager("ocaml")),
                *arguments,
                *self.context.arguments(
                    "opamCommon", root=str(self.context.opam)
                ),
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
        identity = hashlib.sha256(str(self.context.opam).encode()).hexdigest()
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
            data.get("root") != str(self.context.opam)
            or data.get("version") != row["version"]
            or data.get("revision") != self.context.data["ocaml"]["revision"]
            or data.get("stage") not in ("create", "handover")
            or not isinstance(data.get("fresh"), bool)
        ):
            raise BootstrapError(
                "Pending opam state does not match this baseline/root"
            )
        return data

    def create(self, row, repository):
        declaration = self.context.data["ocaml"]
        name = self.context.data["policy"]["repositoryName"]
        upstream = self.context.data["policy"]["upstreamName"]
        url = repository.as_uri()
        switch = f"lcs-ocaml-{row['version']}"
        path = self.pending_path(row)
        pending = self.read_pending(row)
        if pending is None:
            pending = {
                "root": str(self.context.opam),
                "version": row["version"],
                "revision": declaration["revision"],
                "stage": "create",
                "fresh": not (self.context.opam / "config").exists(),
            }
            self.save_pending(path, pending)
        if not (self.context.opam / "config").exists():
            if not pending["fresh"] or pending["stage"] != "create":
                raise BootstrapError(
                    "Pending opam root disappeared; inspect it manually"
                )
            self.run(
                *self.context.arguments("opamInit", name=name, url=url),
                timeout=self.context.data["policy"]["timeouts"]["repository"],
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
        target = self.context.opam / switch
        if not target.exists():
            if pending["stage"] != "create":
                raise BootstrapError(
                    "Pending switch disappeared; inspect it manually"
                )
            self.run(
                *self.context.arguments("opamRegister", name=name, url=url),
                timeout=self.context.data["policy"]["timeouts"]["repository"],
            )
            self.run(
                *self.context.arguments(
                    "opamCreate",
                    switch=switch,
                    version=row["version"],
                    name=name,
                ),
                timeout=self.context.data["policy"]["timeouts"]["ocaml"],
                env=self.context.data.get("setup", {}).get(
                    "buildEnvironment", {}
                ),
                source_build=True,
            )
        self.context.verify_runtime(row)
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
                "opamRegister",
                name=upstream,
                url=self.context.data["policy"]["upstreamUrl"],
            ),
            timeout=self.context.data["policy"]["timeouts"]["repository"],
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
