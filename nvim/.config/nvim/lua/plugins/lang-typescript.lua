-- File: lua/plugins/lang-typescript.lua
return {
  -- 1. MASON: Installs tsserver, prettier (formatter) and eslint (linter)
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(
        opts.ensure_installed,
        { "typescript-language-server", "prettier", "eslint_d" }
      )
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses prettier
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        javascript = { "prettier" },
        typescript = { "prettier" },
        javascriptreact = { "prettier" },
        typescriptreact = { "prettier" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures tsserver
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        typescript_language_server = {},
      },
    },
  },

  -- 4. TREESITTER: Installs the parsers
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "javascript", "typescript", "tsx" })
      end
    end,
  },
}
