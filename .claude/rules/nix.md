---
paths:
  - "**/*.nix"
  - "home/**"
  - "darwin/**"
  - "hosts/**"
  - "scripts/**"
---

Hard constraints for this repository. Rationale and depth live in
`README.md`; the `nix-conventions` skill carries the working decisions.

**Never activate before building.** `nix build
.#darwinConfigurations.LCSMacBook-Pro.system --no-link` must succeed
before any `darwin-rebuild switch`. No CI runner builds the whole system,
so a switch is the first thing that ever compiles it. Remove the `result`
symlink afterwards — it is a GC root.

**Never introduce `mkOutOfStoreSymlink` without registering it** in
`home/out-of-store-allowlist.tsv`, with writer, sensitivity, rollback
behaviour, and retirement condition. `scripts/check-out-of-store-allowlist.sh`
fails on an unregistered symlink or a stale entry.

**Never change `homebrew.onActivation.cleanup` from `"none"`.** The other
modes uninstall whatever is installed but undeclared, and the Homebrew
inventory here is deliberately incomplete during the migration.

**Never duplicate a Home Manager module per host.** Gate platform
differences inside the shared `home/<app>/` module with
`lib.mkIf pkgs.stdenv.hostPlatform.isDarwin` / `hostPlatform.isLinux`.

**Never derive `dotfilesRoot` from the flake path.** The flake is
store-copied; deriving it there makes writable configs read-only. Host
facts belong in the `flake.nix` let-block.

**Never write user state into the repository or the store.** Persistent
state goes to `XDG_STATE_HOME`, application data to `XDG_DATA_HOME`,
disposable data to `XDG_CACHE_HOME`. A tracked file that an application
writes to is a bug unless it is an explicitly documented first-run seed.

When a check script rejects a change, fix the change or update the
registry with justification. Do not silence the check.
