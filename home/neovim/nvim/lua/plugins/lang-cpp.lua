-- =====-----------------------------------------------------------------=====
-- C / C++
--
-- lazyvim.plugins.extras.lang.clangd (enabled in lazyvim.json) already wires
-- clangd's cmd/capabilities/init_options/root_markers, clangd_extensions.nvim
-- (AST view, inlay hints), the source/header switch keymap, and codelldb via
-- the dap.core extra. This file only redirects clangd and clang-format off
-- Mason and onto home/llvm's Nix-managed clang-tools (already on PATH),
-- matching every other language here that owns its own toolchain.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. NVIM-LSPCONFIG: don't let Mason manage clangd; home/llvm provides it.
  {
    "neovim/nvim-lspconfig",
    ft = { "c", "cpp" },
    opts = {
      servers = {
        clangd = { mason = false },
      },
    },
  },

  -- 2. CONFORM.NVIM (Formatter): clang-format, also from home/llvm.
  {
    "stevearc/conform.nvim",
    ft = { "c", "cpp" },
    opts = {
      formatters_by_ft = {
        c = { "clang_format" },
        cpp = { "clang_format" },
      },
    },
  },

  -- 3. TREESITTER: Ensure C/C++ parsers are installed (the clangd extra only
  -- adds "cpp"; "c" is added here for plain-C files).
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "c", "cpp" },
    opts = require("lang_util").treesitter_ensure({ "c", "cpp" }),
  },
}
