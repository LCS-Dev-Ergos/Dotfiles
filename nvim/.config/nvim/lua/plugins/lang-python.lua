-- File: lua/plugins/lang-python.lua
return {
  -- 1. MASON: Installs pyright (LSP), ruff (linter/formatter) and debugpy (debugger).
  {
    "mason-org/mason.nvim",
    ft = { "python" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "pyright", "ruff", "debugpy" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses ruff.
  {
    "stevearc/conform.nvim",
    ft = { "python" },
    opts = {
      formatters_by_ft = {
        python = { "ruff_format" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures pyright.
  {
    "neovim/nvim-lspconfig",
    ft = { "python" },
    opts = {
      servers = {
        pyright = {},
      },
    },
  },

  -- 4. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "python" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "python" })
      end
    end,
  },
}
