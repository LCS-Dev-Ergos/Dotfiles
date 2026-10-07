"""Install retained Node/Python seeds through native managers."""

import hashlib
import http.server
import os
import shutil
import tarfile
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from support import BootstrapError, run, writable_directory


class SeedRuntimes:
    def __init__(self, context):
        self.context = context

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
    def node_mirror(release, archive):
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
    def verify_node_tree(archive, installation):
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

    def install_node(self, row):
        release = next(
            item
            for item in self.context.data["node"]
            if item["version"] == row["version"]
        )
        archive = self.artifact(release)
        writable_directory(self.context.fnm)
        writable_directory(self.context.fnm / "node-versions")
        with tempfile.TemporaryDirectory(
            prefix=".devrestore-", dir=self.context.fnm
        ) as temporary:
            staged_root = Path(temporary)
            with self.node_mirror(release, archive) as mirror:
                run(
                    [
                        str(self.context.manager("node")),
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
            self.verify_node_tree(archive, staged / "installation")
            self.context.verify_runtime(
                dict(row, path=str(staged / "installation/bin/node"))
            )
            target = self.context.fnm / "node-versions" / staged.name
            target.parent.mkdir(mode=0o700, exist_ok=True)
            if os.path.lexists(target):
                raise BootstrapError(
                    "Node target appeared during installation; refusing overwrite"
                )
            staged.rename(target)

    def install_python(self, row):
        builder = self.context.data["python"]["builder"]
        expected = (
            f"python-build {self.context.data['python']['pythonBuildVersion']}"
        )
        if run([builder, "--version"]) != expected:
            raise BootstrapError(
                f"Python recovery requires immutable {expected}"
            )
        source_cache = Path(self.context.data["python"]["sourceCache"])
        for source in self.context.data["python"].get("sources", []):
            with (source_cache / source["name"]).open("rb") as file:
                if (
                    hashlib.file_digest(file, "sha256").hexdigest()
                    != source["sha256"]
                ):
                    raise BootstrapError(
                        f"Python source checksum mismatch: {source['name']}"
                    )
        definition = Path(self.context.data["python"]["definition"])
        target = self.context.pyenv / "versions" / row["version"]
        if os.path.lexists(target):
            raise BootstrapError("Python target appeared; refusing overwrite")
        writable_directory(self.context.cache)
        writable_directory(self.context.pyenv)
        writable_directory(self.context.pyenv / "versions")
        run(
            [
                builder,
                *self.context.arguments(
                    "pythonBuild",
                    definition=str(definition),
                    target=str(target),
                ),
            ],
            env={
                **self.context.data.get("setup", {}).get(
                    "buildEnvironment", {}
                ),
                "PYENV_ROOT": str(self.context.pyenv),
                "PYTHON_BUILD_CACHE_PATH": self.context.data["python"][
                    "sourceCache"
                ],
            },
            source_build=True,
            timeout=self.context.data["policy"]["timeouts"]["python"],
            cwd=str(self.context.cache),
        )
        run(
            [
                str(self.context.manager("python")),
                *self.context.arguments("pythonRehash"),
            ],
            env={"PYENV_ROOT": str(self.context.pyenv)},
        )
