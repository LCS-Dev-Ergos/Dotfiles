-- =====-----------------------------------------------------------------=====
-- PYTHON
--
-- basedpyright (LSP), ruff (linter/formatter), and debugpy (debugger) all
-- come from Mason.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Installs basedpyright, ruff, and debugpy.
  {
    "mason-org/mason.nvim",
    ft = { "python" },
    opts = require("lang_util").mason_ensure({ "basedpyright", "ruff", "debugpy" }),
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

  -- 3. NVIM-LSPCONFIG: Configures basedpyright.
  {
    "neovim/nvim-lspconfig",
    ft = { "python" },
    opts = {
      servers = {
        basedpyright = {},
      },
    },
  },

  -- 4. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "python" },
    opts = require("lang_util").treesitter_ensure({ "python" }),
  },
}
