-- =====-----------------------------------------------------------------=====
-- KOTLIN
--
-- kotlin-language-server comes from Mason. ktlint (formatter) comes from
-- home/doom/default.nix (Nix) and is already on PATH, so only the LSP needs
-- Mason to manage it.
--
-- lazyvim.json still enables lazyvim.plugins.extras.lang.kotlin for its
-- treesitter/lspconfig/debug-adapter wiring, but that extra also declares
-- Mason's own ktlint, duplicating the Nix-installed copy. Exclude it or
-- Mason silently reinstalls it.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Installs the LSP; excludes the LazyVim extra's ktlint duplicate.
  {
    "mason-org/mason.nvim",
    ft = { "kotlin" },
    opts = require("lang_util").mason_ensure({ "kotlin-language-server" }),
  },
  {
    "mason-org/mason.nvim",
    ft = { "kotlin" },
    opts = require("lang_util").mason_exclude({ "ktlint" }),
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
