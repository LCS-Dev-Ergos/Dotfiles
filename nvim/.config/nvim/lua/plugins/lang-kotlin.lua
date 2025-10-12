-- File: lua/plugins/lang-kotlin.lua

return {
  -- 1. MASON: Ensure LSP and formatter are installed.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "kotlin-language-server", "ktlint" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Use ktlint for Kotlin files.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { kotlin = { "ktlint" } },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configure the language server (kotlin_language_server).
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        kotlin_language_server = {},
      },
    },
  },

  -- 4. TREESITTER: Ensure the parser for Kotlin is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "kotlin" })
      end
    end,
  },
}
