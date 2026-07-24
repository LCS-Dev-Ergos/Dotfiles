-- =====-----------------------------------------------------------------=====
-- KOTLIN
--
-- kotlin-language-server comes from Mason. ktlint (formatter) comes from
-- home/doom/default.nix (Nix) and is already on PATH, so only the LSP needs
-- Mason to manage it.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Installs the LSP.
  {
    "mason-org/mason.nvim",
    ft = { "kotlin" },
    opts = require("lang_util").mason_ensure({ "kotlin-language-server" }),
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
    opts = require("lang_util").treesitter_ensure({ "kotlin" }),
  },
}
