-- File: lua/plugins/lang-typescript.lua
-- LazyVim's lang.typescript and formatting.prettier extras handle the LSP,
-- formatter, and treesitter. This file adds inlay hints and eslint_d linting.
return {
  -- Inlay hints: parameter names, types, return types for TypeScript/JavaScript.
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

  -- Mason: eslint_d for linting (ts-server handled by LazyVim's typescript extra).
  {
    "mason-org/mason.nvim",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "eslint_d" })
    end,
  },

  -- nvim-lint: eslint_d.
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
