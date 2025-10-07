-- File: lua/plugins/lang-python.lua
return {
  -- 1. MASON: Installa pyright (LSP), ruff (linter/formatter) e debugpy (debugger)
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "pyright", "ruff", "debugpy" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Usa ruff
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        python = { "ruff_format" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configura pyright
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {},
      },
    },
  },

  -- 4. TREESITTER: Installa il parser
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "python" })
      end
    end,
  },
}
