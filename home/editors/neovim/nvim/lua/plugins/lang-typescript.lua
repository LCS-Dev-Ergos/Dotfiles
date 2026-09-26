-- =====-----------------------------------------------------------------=====
-- TYPESCRIPT / JAVASCRIPT
--
-- LazyVim's lang.typescript and formatting.prettier extras already handle
-- the LSP, formatter, and treesitter parsers. This file only adds inlay
-- hints and eslint_d linting (eslint_d comes from Mason).
-- =====-----------------------------------------------------------------=====

return {
  -- 1. NVIM-LSPCONFIG: Inlay hints (parameter names, types, return types).
  {
    "neovim/nvim-lspconfig",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
    opts = {
      servers = {
        ts_ls = {
          settings = {
            typescript = {
              inlayHints = {
                includeInlayParameterNameHints = "all",
                includeInlayParameterNameHintsWhenArgumentMatchesName = false,
                includeInlayFunctionParameterTypeHints = true,
                includeInlayVariableTypeHints = true,
                includeInlayPropertyDeclarationTypeHints = true,
                includeInlayFunctionLikeReturnTypeHints = true,
                includeInlayEnumMemberValueHints = true,
              },
            },
            javascript = {
              inlayHints = {
                includeInlayParameterNameHints = "all",
                includeInlayParameterNameHintsWhenArgumentMatchesName = false,
                includeInlayFunctionParameterTypeHints = true,
                includeInlayVariableTypeHints = true,
                includeInlayPropertyDeclarationTypeHints = true,
                includeInlayFunctionLikeReturnTypeHints = true,
                includeInlayEnumMemberValueHints = true,
              },
            },
          },
        },
      },
    },
  },

  -- 2. MASON: eslint_d for linting (ts-server handled by LazyVim's typescript extra).
  {
    "mason-org/mason.nvim",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
    opts = require("lang_util").mason_ensure({ "eslint_d" }),
  },

  -- 3. NVIM-LINT: eslint_d.
  {
    "mfussenegger/nvim-lint",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
    opts = {
      linters_by_ft = {
        javascript = { "eslint_d" },
        typescript = { "eslint_d" },
        javascriptreact = { "eslint_d" },
        typescriptreact = { "eslint_d" },
      },
    },
  },
}
