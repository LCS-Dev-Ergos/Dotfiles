-- File: lua/plugins/lang-go.lua
--
-- Overrides LazyVim's lang.go extra (lazyvim.json) to use the Go toolchain's
-- own tools, already on PATH, instead of Mason's private copies:
--   gopls, goimports, gofumpt, golangci-lint -> `go install ...@latest`
--   dlv (debugger)                           -> `go install golang.org/x/tools/cmd/dlv@latest`
--   impl                                     -> `go install github.com/josharian/impl@latest`
--   gomodifytags                             -> home/doom/default.nix (Nix)
--
-- Go tools that need cgo (golangci-lint) require CC set to Apple's clang:
-- `go env -w CC=/usr/bin/cc`. The Nix clang wrapper that's on PATH doesn't
-- carry the macOS SDK outside a proper Nix derivation sandbox.

return {
  -- 1. NVIM-LSPCONFIG: gopls resolves via PATH, not Mason's registry path.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gopls = { mason = false },
      },
    },
  },

  -- 2. MASON: The tools above come from the Go toolchain instead.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      local skip = {
        gopls = true,
        goimports = true,
        gofumpt = true,
        delve = true,
        impl = true,
        gomodifytags = true,
        ["golangci-lint"] = true,
      }
      opts.ensure_installed = vim.tbl_filter(
        function(pkg) return not skip[pkg] end,
        opts.ensure_installed or {}
      )
    end,
  },
}
