# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Immutable Deployment and Plugin Updates

Home Manager deploys this directory through the Nix store. Neovim's plugins,
Mason tools, caches, ShaDa, sessions, and logs remain writable in their normal
XDG data, cache, and state directories; configuration files do not.

`lazy-lock.json` is reviewed configuration even though Lazy rewrites its lock
after both plugin installation and updates. Home Manager synchronizes the
declared lock into `XDG_STATE_HOME/nvim/lazy-lock.json` on every activation;
ordinary Lazy operations therefore never write into the Nix store.

Use `nvim-update-lock` for a deliberate repository update. The command requires
the checkout and runtime state to match the active generation, lets Lazy update
a temporary lock, validates the result, and promotes it atomically to the
checkout and runtime state. If Lazy fails, it attempts to restore live plugins
to the active lock before returning an error.

After a successful update, review and commit `lazy-lock.json`, then switch the
Nix generation. An interactive `:Lazy update` can modify only runtime state,
not the repository. That drift is intentionally rejected by
`nvim-update-lock`; switch once to restore the declared baseline, then run the
updater. Use `nvim-update-lock --check` for a read-only three-way baseline
check.
