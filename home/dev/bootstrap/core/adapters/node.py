"""Node through FNM, seeded from Nix-retained archives over loopback."""

import hashlib
import http.server
import os
import shutil
import tarfile
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import writable_directory
from .base import Adapter

# fnm records `fnm default system` as a link to this placeholder.
FNM_SYSTEM_TARGET = "/dev/null/installation"


class NodeAdapter(Adapter):
    language = "node"
    manager_name = "fnm"
    runtime_directory = "node-versions"

    def resolve_roots(self):
        data = os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share"
        return {"FNM_DIR": self.locate("FNM_DIR", Path(data) / "fnm")}

    def manager_candidates(self):
        """The canonical command, then FNM's local single-command exposure."""
        if not self.recipe:
            return None
        directory = Path(self.recipe["managerDirectory"])
        return [directory / self.recipe["managers"]["node"], self.root / "fnm"]

    def readiness(self):
        self.check_manager_release()
        writable_directory(self.root)
        link = self.root / "fnm"
        native = self.manager()
        # Existing shell adapters prioritize this single-command directory
        # when native readiness is enabled, without promoting all Homebrew.
        if os.path.lexists(link):
            if link.resolve() != native.resolve():
                raise BootstrapError(
                    f"Conflicting native FNM exposure: {link}"
                )
        else:
            link.symlink_to(native)

    def baseline(self):
        return [
            self.row(
                release["version"],
                self.root
                / "node-versions"
                / f"v{release['version']}"
                / "installation/bin/node",
            )
            for release in self.context.data["node"]
        ]

    def prefix(self, row):
        return Path(row["path"]).parents[2]

    def identity(self, row, path):
        return process.run([str(path), "--version"]).removeprefix("v")

    def canary(self, row, path, *, complete):
        process.run([str(path), "-e", "if (1 + 1 !== 2) process.exit(1)"])

    def selection(self):
        alias = self.root / "aliases/default"
        return os.readlink(alias) if alias.is_symlink() else None

    def selected_runtime(self):
        alias = self.root / "aliases/default"
        if not alias.is_symlink():
            raise BootstrapError("No valid FNM default alias")
        if os.readlink(alias) == FNM_SYSTEM_TARGET:
            return None
        executable = alias.resolve() / "bin/node"
        if not executable.is_relative_to(self.root):
            raise BootstrapError("FNM default escapes its runtime root")
        return executable

    def initialize_default(self):
        if os.path.lexists(self.root / "aliases/default"):
            return
        process.run(
            [
                str(self.manager()),
                *self.context.arguments(
                    "nodeDefault",
                    root=str(self.root),
                    version=self.context.data["defaults"]["node"],
                ),
            ],
            env={},
            cwd=str(self.context.state),
        )

    # Installation from the retained archive ----------------------------------

    def artifact(self, release):
        """Validate the Nix-fetched archive before any manager mutation."""
        path = Path(release["archive"])
        if not path.is_absolute():
            raise BootstrapError("Node archive must be an absolute path")
        with path.open("rb") as handle:
            if (
                hashlib.file_digest(handle, "sha256").hexdigest()
                != release["hashes"][self.context.data["platform"]]
            ):
                raise BootstrapError("Node archive checksum mismatch")
        return path

    @staticmethod
    @contextmanager
    def mirror(release, archive):
        """FNM's HTTP-only mirror consumes one immutable archive over loopback."""
        route = f"/v{release['version']}/{release['filename']}"

        class ArchiveHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != route:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(archive.stat().st_size))
                self.end_headers()
                with archive.open("rb") as source:
                    shutil.copyfileobj(source, self.wfile)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), ArchiveHandler
        )
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    @staticmethod
    def verify_tree(archive, installation):
        """Compare FNM extraction with the locked archive before executing Node."""
        expected = set()
        with tarfile.open(archive) as tar:
            for member in tar:
                relative = Path(*Path(member.name).parts[1:])
                if not relative.parts:
                    continue
                if member.name.startswith("/") or ".." in relative.parts:
                    raise BootstrapError("Unsafe archive member")
                path = installation / relative
                if member.isfile():
                    expected.add(relative)
                    if path.is_symlink() or not path.is_file():
                        raise BootstrapError(
                            f"Node extraction mismatch: {relative}"
                        )
                    with (
                        path.open("rb") as handle,
                        tar.extractfile(member) as archived,
                    ):
                        if (
                            hashlib.file_digest(handle, "sha256").digest()
                            != hashlib.file_digest(archived, "sha256").digest()
                        ):
                            raise BootstrapError(
                                f"Node extraction checksum mismatch: {relative}"
                            )
                elif member.issym():
                    expected.add(relative)
                    if (
                        not path.is_symlink()
                        or os.readlink(path) != member.linkname
                    ):
                        raise BootstrapError(
                            f"Node extraction link mismatch: {relative}"
                        )
                    if not path.resolve().is_relative_to(
                        installation.resolve()
                    ):
                        raise BootstrapError(
                            "Node archive link escapes its installation"
                        )
                elif not member.isdir():
                    raise BootstrapError("Unsupported Node archive member")
        actual = {
            path.relative_to(installation)
            for path in installation.rglob("*")
            if path.is_file() or path.is_symlink()
        }
        if actual != expected:
            raise BootstrapError(
                "Node extraction contains missing or additional files"
            )

    def install(self, row):
        release = next(
            item
            for item in self.context.data["node"]
            if item["version"] == row["version"]
        )
        archive = self.artifact(release)
        writable_directory(self.root)
        writable_directory(self.root / "node-versions")
        with tempfile.TemporaryDirectory(
            prefix=".devrestore-", dir=self.root
        ) as temporary:
            staged_root = Path(temporary)
            with self.mirror(release, archive) as mirror:
                process.run(
                    [
                        str(self.manager()),
                        *self.context.arguments(
                            "nodeInstall",
                            staging=temporary,
                            mirror=mirror,
                            version=row["version"],
                        ),
                    ],
                    env={
                        "FNM_COREPACK_ENABLED": "false",
                        "NO_PROXY": "127.0.0.1",
                        "no_proxy": "127.0.0.1",
                    },
                    timeout=self.context.data["policy"]["timeouts"]["node"],
                    cwd=temporary,
                )
            staged = staged_root / "node-versions" / f"v{row['version']}"
            self.verify_tree(archive, staged / "installation")
            self.verify(dict(row, path=str(staged / "installation/bin/node")))
            target = self.root / "node-versions" / staged.name
            target.parent.mkdir(mode=0o700, exist_ok=True)
            if os.path.lexists(target):
                raise BootstrapError(
                    "Node target appeared during installation; refusing overwrite"
                )
            staged.rename(target)
