-- File: lua/plugins/lang-kotlin.lua

return {
  -- 1. MASON: Installs the LSP. ktlint comes from home/doom/default.nix
  -- (Nix) and is already on PATH.
  {
    "mason-org/mason.nvim",
    ft = { "kotlin" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "kotlin-language-server" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Use ktlint for Kotlin files.
  {
    "stevearc/conform.nvim",
    ft = { "kotlin" },
    opts = {
      formatters_by_ft = { kotlin = { "ktlint" } },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configure the language server (kotlin_language_server).
  {
    "neovim/nvim-lspconfig",
    ft = { "kotlin" },
    opts = {
      servers = {
        kotlin_language_server = {},
      },
    },
  },

  -- 4. TREESITTER: Ensure the parser for Kotlin is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "kotlin" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "kotlin" })
      end
    end,
  },
}
