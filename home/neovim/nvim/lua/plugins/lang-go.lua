-- =====-----------------------------------------------------------------=====
-- GO
--
-- Overrides LazyVim's lang.go extra (lazyvim.json) to use the Go toolchain's
-- own tools, already on PATH, instead of Mason's private copies:
--   gopls, goimports, gofumpt, golangci-lint -> `go install ...@latest`
--   dlv (debugger)                           -> `go install golang.org/x/tools/cmd/dlv@latest`
--   impl                                     -> `go install github.com/josharian/impl@latest`
--   gomodifytags                             -> home/doom/default.nix (Nix)
--
-- Go tools that need cgo (golangci-lint) use the declarative CC/CXX written
-- by home/llvm. On Darwin those resolve to LLVM 22 with the pinned macOS 26
-- SDK, both through the environment and Go's Home Manager-owned env file.
-- =====-----------------------------------------------------------------=====

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
    opts = require("lang_util").mason_exclude({
      "gopls",
      "goimports",
      "gofumpt",
      "delve",
      "impl",
      "gomodifytags",
      "golangci-lint",
    }),
  },
}
