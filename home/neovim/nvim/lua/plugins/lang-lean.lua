-- =====-----------------------------------------------------------------=====
-- LEAN 4
--
-- Functional programming language and interactive theorem prover. lean.nvim
-- manages its own LSP connection (lean-language-server via lake), so there is
-- no Mason, Conform, or separate NVIM-LSPCONFIG section here.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. LEAN.NVIM: LSP integration, infoview (goals/messages), and unicode input.
  {
    "Julian/lean.nvim",
    ft = { "lean" },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "neovim/nvim-lspconfig",
    },
    opts = {
      -- Default <localleader> mappings: <localleader>i toggles the infoview,
      -- <localleader>p pauses it, <localleader>x clears the goal, etc.
      mappings = true,
      -- Unicode abbreviations typed after '\': \N -> ℕ, \alpha -> α, etc.
      abbreviations = { enable = true },
      infoview = {
        -- Open the infoview automatically when a Lean buffer is opened.
        autoopen = true,
      },
    },
  },

  -- 2. TREESITTER: Lean 4 parser for syntax highlighting.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "lean" },
    opts = require("lang_util").treesitter_ensure({ "lean" }),
  },
}
