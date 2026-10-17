"""Resolve the host-bound values of VS Code's user settings.json.

One settings.json travels between macOS, Linux and Windows, but some of its
values only make sense on the machine that wrote them: where clangd, cmake or
a JDK live. The package resolves those values for the machine it runs on and
writes them back, and touches nothing else:

- Only the keys of the manifest are written. Comments, key order, indentation,
  line endings and every other value stay byte for byte as they were.
- A value is written only after its target was found on disk. Nothing is
  guessed and nothing found is executed.
- The edited text is parsed again and compared with the original before the
  file is replaced, so an editing bug aborts the run instead of damaging it.
- Keys that do not exist yet go into one generated block at the end of the
  file, and every managed key is added to ``settingsSync.ignoredSettings`` so
  Settings Sync does not carry one machine's paths to another.

Modules, in dependency order: ``jsonc`` parses, ``text`` edits, ``host``
describes the machine, ``resolvers`` and ``manifest`` say what is managed and
how it is found, ``plan`` works out the edits, ``storage`` reads and replaces
the file, ``report`` formats results and ``cli`` ties them together.
"""

__version__ = "1.0.0"

PROG = "vscode-host-settings"
"""The command name, also used for the state directory and block markers."""
