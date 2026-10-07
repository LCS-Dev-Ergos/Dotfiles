"""Offline regressions for the workstation security boundaries corrected in 2026-10.

Run with python3 scripts/tests/security_regressions.py. Fixtures and command
spies live below TMPDIR; no real upload, desktop operation or permission grant.
"""

import glob
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PLUGINS = REPO / "home/file-managers/nnn/plugins"
DESKTOP = REPO / "home/desktop/hyprdots/hyprdots/scripts"


class SecurityRegressions(unittest.TestCase):
    """Exercise hostile inputs and ordinary controls through repository helpers."""

    def setUp(self):
        """Create a private home, GNU tool aliases and command log for each test.

        Register cleanup before creating fixtures so failures cannot retain
        files or redirect a subsequent test into the user's real configuration.
        """
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # macOS exposes temporary paths through /var -> /private/var; compare
        # canonical paths so containment checks test the helper, not that alias.
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir(mode=0o700)
        self.bin.mkdir(mode=0o700)
        self.log = self.root / "argv.jsonl"
        self.marker = self.root / "injected"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}",
                        XDG_CACHE_HOME=str(self.home / ".cache"), XDG_CONFIG_HOME=str(self.home / ".config"),
                        ARGV_LOG=str(self.log), MARKER=str(self.marker))
        for name in ("sort", "uniq", "md5sum", "stat", "readlink", "realpath", "sed"):
            binary = shutil.which("g" + name) or shutil.which(name)
            if binary:
                (self.bin / name).symlink_to(binary)
        finds = glob.glob("/nix/store/*findutils*/bin/find")
        (self.bin / "find").symlink_to(finds[0] if finds else (shutil.which("gfind") or shutil.which("find")))

    def script(self, path, code):
        """Write an executable POSIX shell fixture and return its path."""
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + code)
        path.chmod(0o700)
        return path

    def spy(self, name, suffix=""):
        """Install a Python command spy that records argv and runs fixture code.

        The optional suffix supplies a mock response or isolated side effect;
        it never delegates to the real upload, desktop or privilege command.
        """
        code = (f"#!{shutil.which('python3')}\nimport json,os,sys\n"
                "with open(os.environ['ARGV_LOG'],'a') as f: f.write(json.dumps(sys.argv)+'\\n')\n" + suffix)
        path = self.bin / name
        path.write_text(code)
        path.chmod(0o700)
        return path

    def run_command(self, argv, *, env=None, **kwargs):
        """Run a helper in the fixture with captured output and a ten-second limit.

        Callers may override the fixture environment, cwd or subprocess input;
        the returned CompletedProcess exposes both security and control results.
        """
        return subprocess.run(argv, env=env or self.env, cwd=kwargs.pop("cwd", self.root),
                              text=True, capture_output=True, timeout=10, **kwargs)

    def args(self):
        """Return argv records from command spies, or an empty list before use."""
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_python_selector_and_fallback_are_bounded(self):
        """Reject path selectors while preserving installed names and probe modes.

        Cover unchecked secondary lines, comments, CRLF, the sanitized shim,
        virtualenv metadata and PATH fallback; Starship must use only the helper.
        """
        probe = REPO / "home/shells/starship/scripts/python-version.sh"
        pyenv = self.home / ".pyenv"
        shim = self.script(pyenv / "shims/python", 'printf "shim %s\\n" "$PYENV_VERSION"\n')
        installed = self.script(pyenv / "versions/3.12.1/bin/python", 'printf "Python 3.12.1\\n"\n')
        env = dict(self.env, PATH=f"{shim.parent}:{self.env['PATH']}", PYENV_ROOT=str(pyenv))
        env.pop("VIRTUAL_ENV", None)
        env.pop("PYENV_VERSION", None)
        version = self.root / ".python-version"
        for selector in ("../payload", "..", "/tmp/payload", "bad:../payload"):
            version.write_text(selector + "\n")
            result = self.run_command(["sh", str(probe), "--version"], env=env)
            self.assertNotEqual(result.returncode, 0, result)
            self.assertNotIn("shim", result.stdout)
        version.write_text("3.12.1\n../../payload\n")
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "Python 3.12.1\n")
        version.write_text("# Project Python\n\n3.12.1\n")
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "Python 3.12.1\n")
        version.write_text("# Project Python\r\n3.12.1\r\n")
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "Python 3.12.1\n")
        installed.unlink()
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "shim 3.12.1\n")
        version.write_text("system\n")
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "shim system\n")
        venv = self.root / ".venv"
        venv.mkdir()
        (venv / "pyvenv.cfg").write_text("version = 3.13.2\n")
        self.assertEqual(self.run_command(["sh", str(probe)], env=env).stdout, "Python 3.13.2\n")
        (venv / "pyvenv.cfg").unlink()
        self.script(self.bin / "python", 'printf "Python 3.11.9\\n"\n')
        self.assertEqual(self.run_command(["sh", str(probe)]).stdout, "Python 3.11.9\n")
        nix = (REPO / "home/shells/starship/default.nix").read_text()
        self.assertIn('python.python_binary = [ "${pythonVersion}" ];', nix)

    def test_selection_names_remain_arguments(self):
        """Keep hostile nnn selection names in argv for chmod and KDE Connect.

        Quotes, command syntax, newlines and leading hyphens must round-trip;
        the selection FIFO must still receive its normal clear signal.
        """
        names = ['$(touch "$MARKER")', 'quote" and space', "line\nbreak", "-option", "`touch injected`"]
        files = [self.root / name for name in names]
        for path in files:
            path.touch()
        selection = self.root / "selection"
        selection.write_bytes(b"\0".join(os.fsencode(p) for p in files) + b"\0")
        env = dict(self.env, NNN_SEL=str(selection), NNN_PIPE="")
        self.spy("chmod")
        result = self.run_command(["sh", str(PLUGINS / "togglex")], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([a[-1] for a in self.args()], [str(p) for p in files])
        self.assertTrue(all(a[-2] == "--" for a in self.args()))
        self.log.unlink()
        self.spy("kdeconnect-cli", "if '--list-available' in sys.argv: print('test-device')\n")
        pipe = self.root / "pipe"
        os.mkfifo(pipe, 0o600)
        fd = os.open(pipe, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, fd)
        env["NNN_PIPE"] = str(pipe)
        result = self.run_command(["sh", str(PLUGINS / "kdeconnect")], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        shared = [a[-1] for a in self.args() if "--share" in a]
        self.assertEqual(shared, [str(p) for p in files])
        self.assertEqual(os.read(fd, 1), b"-")
        self.assertFalse(self.marker.exists())

    def test_duplicate_detection_hashes_data_and_refuses_newlines(self):
        """Find real duplicates without executing names or misrepresenting rows.

        The editor sees only equal-content files and cancellation remains safe;
        newline names fail explicitly before the line-based review can proceed.
        """
        first, second = self.root / '$(touch "$MARKER")', self.root / 'quote" and \\ slash'
        first.write_text("identical")
        second.write_text("identical")
        (self.root / "not-duplicate").write_text("different")
        self.spy("editor", "print(open(sys.argv[1]).read())\n")
        result = self.run_command(["sh", str(PLUGINS / "dups")], env=dict(self.env, EDITOR="editor"), input="n\nx\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(first.name, result.stdout)
        self.assertIn(second.name, result.stdout)
        self.assertNotIn("./not-duplicate", result.stdout)
        self.assertFalse(self.marker.exists())
        (self.root / "line\nbreak").write_text("identical")
        result = self.run_command(["sh", str(PLUGINS / "dups")], env=dict(self.env, EDITOR="editor"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("newlines", result.stderr)

    def test_image_editor_templates_do_not_parse_filename(self):
        """Pass a hostile image name once to each documented editor placeholder.

        Bare, double-quoted and single-quoted templates must preserve one argv
        value; mock upload and notification commands keep the test offline.
        """
        self.spy("editor")
        self.script(self.bin / "curl", 'printf \'%s\\n\' \'{"success":true,"id":"x","link":"https://i.imgur.com/x.png","deletehash":"d"}\'\n')
        self.script(self.bin / "terminal-notifier", "exit 0\n")
        self.script(self.bin / "notify-send", "exit 0\n")
        settings = self.home / ".config/imgur-screenshot/settings.conf"
        settings.parent.mkdir(parents=True)
        settings.write_text('check_update=false\ncopy_url=false\nopen=false\n')
        image = self.root / 'image $(touch "$MARKER") \'"\n.png'
        image.touch()
        for template in ('editor %img', 'editor "%img"', "editor '%img'"):
            result = self.run_command(["bash", str(PLUGINS / "imgur"), "--edit-command", template, str(image)], input="\n")
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(self.args()[-1][1:], [str(image)])
            self.assertFalse(self.marker.exists())

    def test_private_cache_rejects_redirected_existing_state(self):
        """Accept private thumbnail storage and reject links or shared cache state.

        Check directory/file symlinks, hard links and permissive roots while
        preserving reuse of an ordinary owned thumbnail.
        """
        helper = PLUGINS / ".preview-cache"
        cache = self.home / ".cache/nnn/previews"
        result = self.run_command(["python3", str(helper), str(cache)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        victim = self.root / "victim"
        victim.mkdir()
        for directory in (True, False):
            redirected = cache / "redirect"
            redirected.symlink_to(victim, target_is_directory=directory)
            result = self.run_command(["python3", str(helper), str(cache)])
            self.assertNotEqual(result.returncode, 0)
            redirected.unlink()
        cached = cache / "image.jpg"
        cached.write_text("legitimate thumbnail")
        self.assertEqual(self.run_command(["python3", str(helper), str(cache)]).returncode, 0)
        (cache / "linked.jpg").hardlink_to(cached)
        self.assertNotEqual(self.run_command(["python3", str(helper), str(cache)]).returncode, 0)
        (cache / "linked.jpg").unlink()
        cache.chmod(0o755)
        self.assertNotEqual(self.run_command(["python3", str(helper), str(cache)]).returncode, 0)

    def test_gpu_cache_is_literal_and_private(self):
        """Parse GPU cache fields as data and retain ordinary GPU selection.

        Embedded shell syntax must not run; a symlinked query and a traversal
        selector must fail instead of reading or changing an outside object.
        """
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        cache = runtime / f"hyprdots-{os.geteuid()}-gpuinfo"
        cache.mkdir(mode=0o700)
        query = cache / "query"
        query.write_text('touch "$MARKER"\nnvidia_gpu="$(touch \'injected\')"\namd_flag=1\nintel_flag=1\nprioGPU=amd_flag\n')
        query.chmod(0o600)
        env = dict(self.env, XDG_RUNTIME_DIR=str(runtime), WLR_DRM_DEVICES="")
        result = self.run_command(["bash", str(DESKTOP / "gpuinfo.sh"), "--toggle"], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("intel", result.stdout)
        self.assertIn("prioGPU=intel_flag", query.read_text())
        self.assertFalse(self.marker.exists())
        query.unlink()
        query.symlink_to(self.root / "outside")
        self.assertNotEqual(self.run_command(["bash", str(DESKTOP / "gpuinfo.sh"), "--toggle"], env=env).returncode, 0)
        self.assertNotEqual(self.run_command(["bash", str(DESKTOP / "gpuinfo.sh"), "--use", "../../escape"], env=env).returncode, 0)

    def test_preview_converter_and_source_traversal(self):
        """Confine generated previews after canonicalizing an aliased source path.

        Run preview-tui with mocked media tools, assert ffmpeg receives the
        resolved input, and inspect the generated thumbnail inside private cache.
        """
        self.script(self.bin / "clear", "exit 0\n")
        self.script(self.bin / "tput", "printf '80\\n'\n")
        self.script(self.bin / "file", "printf 'audio/mpeg\\n'\n")
        self.spy("ffmpeg", "from pathlib import Path\nPath(sys.argv[-2]).write_text('generated album art')\n")
        self.spy("chafa")
        fifo = self.root / "input.fifo"
        fifo.write_text("close\n")
        (self.root / "sub").mkdir()
        source = self.root / "audio.mp3"
        source.write_text("mock media")
        env = dict(self.env, PREVIEW_MODE="1", NNN_FIFO=str(fifo), NNN_TERMINAL="test",
                   NNN_PREVIEWIMGPROG="chafa", NNN_SCOPE="0", NNN_PISTOL="0", KITTY_WINDOW_ID="")
        result = self.run_command(["bash", str(PLUGINS / "preview-tui"), "sub/../audio.mp3"], env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        converter = [a for a in self.args() if Path(a[0]).name == "ffmpeg"]
        self.assertEqual(len(converter), 1)
        output = Path(converter[0][-2])
        cache = self.home / ".cache/nnn/previews"
        self.assertTrue(output.is_relative_to(cache))
        self.assertNotIn("..", output.parts)
        self.assertEqual(output.read_text(), "generated album art")
        self.assertEqual(converter[0][2], str(source))


    def test_wallpaper_reader_preserves_literal_paths(self):
        """Expand only a leading home marker without evaluating wallpaper text."""
        text = (DESKTOP / "themeswitch.sh").read_text()
        block = text.split("# wallpaper\n", 1)[1].split('"${ScrDir}/swwwallpaper.sh"', 1)[0]
        control = self.root / "theme.ctl"
        for path, expected in (("~/.config/wall paper.jpg", str(self.home / ".config/wall paper.jpg")),
                               ('$(touch "$MARKER").jpg', '$(touch "$MARKER").jpg'),
                               ("a~b.jpg", "a~b.jpg")):
            control.write_text("1|theme|" + path + "\n")
            result = self.run_command(["bash", "-c", block + '\nprintf "%s" "$getWall"'],
                                      env=dict(self.env, ThemeCtl=str(control)))
            self.assertEqual(result.stdout, expected, result.stderr)
            self.assertFalse(self.marker.exists())

    def test_wallpaper_state_writer_preserves_backslashes(self):
        """Round-trip literal backslashes through both theme-state writers.

        Their POSIX guards must reject actual newline/pipe delimiters while
        accepting backslash spellings, spaces, quotes and dollar signs.
        """
        control = self.root / "theme.ctl"
        for script, expression in (("swwwallkon.sh", 'case "$OPTARG" in'),
                                   ("swwwallpaper.sh", 'case "$1" in')):
            source = (DESKTOP / script).read_text()
            guard = expression + source.split(expression, 1)[1].split("esac", 1)[0] + "esac"
            for path, accepted in ((r"literal\nname.jpg", True),
                                   ("literal\nname.jpg", False), ("literal|name.jpg", False)):
                result = self.run_command(["sh", "-c", "guard() { " + guard +
                                           "; }; guard \"$1\"", "wallpaper-guard", path],
                                          env=dict(self.env, OPTARG=path))
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
        for filename in (r"literal\nname.jpg", r"literal\tname.jpg", "space quote'$.jpg"):
            path = self.root / filename
            control.write_text("1|theme|old.jpg\n")
            source = (DESKTOP / "swwwallkon.sh").read_text()
            block = source.split('    wallpaper_theme="$setTheme"', 1)[1].split('\n    ${ScrDir}/themeswitch.sh', 1)[0]
            result = self.run_command(["bash", "-c", 'wallpaper_theme="$setTheme"' + block],
                                      env=dict(self.env, setTheme="theme", xWall=str(path),
                                               ThemeCtl=str(control), ScrDir=str(self.root)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(control.read_text(), f"1|theme|{path}\n")
            source = (DESKTOP / "swwwallpaper.sh").read_text()
            block = source.split('    wallpaper_theme="$curTheme"', 1)[1].split('\n    ln -fs', 1)[0]
            result = self.run_command(["bash", "-c", 'wallpaper_theme="$curTheme"' + block],
                                      env=dict(self.env, curTheme="theme", x_update=str(path),
                                               ThemeCtl=str(control), ScrDir=str(self.root)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(control.read_text(), f"1|theme|{path}\n")

    def test_spotify_does_not_grant_shared_permissions(self):
        """Stop before privilege or Spicetify calls for a non-writable install.

        A writable fixture must still receive its theme colors, without pkexec;
        no real Spotify installation or permissions are touched.
        """
        scripts = self.root / "scripts"
        scripts.mkdir()
        spotify = self.root / "spotify"
        apps = spotify / "Apps"
        apps.mkdir(parents=True, mode=0o700)
        fixture = scripts / "wallbashspotify.sh"
        fixture.write_text((DESKTOP / "wallbashspotify.sh").read_text().replace("/opt/spotify", str(spotify)))
        self.script(scripts / "globalcontrol.sh", "pkg_installed() { return 0; }\n")
        self.spy("notify-send")
        self.spy("pkexec")
        self.spy("spicetify", "print('color_scheme Wallbash')\n")
        self.script(self.bin / "pgrep", "exit 1\n")
        colors = self.home / ".config/spicetify/Themes/Sleek"
        colors.mkdir(parents=True)
        (colors / "Wall-Dcol.ini").write_text("theme colors")
        apps.chmod(0o500)
        result = self.run_command(["bash", str(fixture)])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(Path(a[0]).name in ("pkexec", "spicetify") for a in self.args()))
        apps.chmod(0o700)
        result = self.run_command(["bash", str(fixture)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((colors / "color.ini").read_text(), "theme colors")
        self.assertFalse(any(Path(a[0]).name == "pkexec" for a in self.args()))

    def test_clipboard_writes_and_native_paste_remain(self):
        """Deny protocol clipboard reads while retaining writes and native paste.

        Inspect both platform policies; interactive Kitty acceptance remains a
        separate deployment check rather than a capability of this static test.
        """
        for platform in ("macos", "linux"):
            text = (REPO / f"home/terminals/kitty/kitty/platform/{platform}.conf").read_text()
            control = next(line for line in text.splitlines() if line.startswith("clipboard_control "))
            self.assertIn("write-clipboard", control)
            self.assertNotIn("read-", control)
            self.assertIn("paste_from_clipboard", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
