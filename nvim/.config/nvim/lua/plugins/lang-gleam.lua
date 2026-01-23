-- File: lua/plugins/lang-gleam.lua
-- Gleam - A friendly language for building type-safe, scalable systems
return {
  -- 1. NVIM-LSPCONFIG: Configures the Gleam language server.
  -- The LSP is built into the Gleam compiler (gleam lsp).
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
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "gleam" })
      end
    end,
  },
}
