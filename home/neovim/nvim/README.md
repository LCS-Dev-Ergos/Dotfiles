# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Immutable Deployment and Plugin Updates

Home Manager deploys this directory through the Nix store. Neovim's plugins,
Mason tools, caches, ShaDa, sessions, and logs remain writable in their normal
XDG data, cache, and state directories; configuration files do not.

`lazy-lock.json` is reviewed configuration even though Lazy writes it during an
update. Use `nvim-update-lock` instead of an interactive `:Lazy update`. The
command requires the checkout and active Nix generation to start from the same
lockfile, lets Lazy update a temporary lock, validates the result, and promotes
it atomically to this checkout. If Lazy fails, it attempts to restore the live
plugins to the active lock before returning an error.

After a successful update, review and commit `lazy-lock.json`, then switch the
Nix generation. Interactive Lazy operations that rewrite the lockfile are not
supported while the configuration is store-backed. Use
`nvim-update-lock --check` for a read-only baseline check.
