-- =====-----------------------------------------------------------------=====
-- GLEAM
--
-- A friendly language for building type-safe, scalable systems. The LSP is
-- built into the Gleam compiler itself (`gleam lsp`), so there is no Mason
-- package and no formatter section: `gleam format` runs through the compiler
-- too, and neither this file nor conform.nvim needs to manage it separately.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. NVIM-LSPCONFIG: Configures the Gleam language server.
  {
    "neovim/nvim-lspconfig",
    ft = { "gleam" },
    opts = {
      servers = {
        gleam = {},
      },
    },
  },

  -- 2. TREESITTER: Ensures the parser for Gleam is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "gleam" },
    opts = require("lang_util").treesitter_ensure({ "gleam" }),
  },
}
