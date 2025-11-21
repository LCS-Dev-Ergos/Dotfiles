-- File: lua/plugins/lang-typescript.lua

return {
  -- 1. MASON: Installs tsserver, prettier (formatter) and eslint_d (linter).
  {
    "mason-org/mason.nvim",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact", "tsx" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(
        opts.ensure_installed,
        { "typescript-language-server", "prettier", "eslint_d" }
      )
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses prettier.
  {
    "stevearc/conform.nvim",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact", "tsx" },
    opts = {
      formatters_by_ft = {
        javascript = { "prettier" },
        typescript = { "prettier" },
        javascriptreact = { "prettier" },
        typescriptreact = { "prettier" },
      },
    },
  },

  -- 3. NVIM-LINT: Configure eslint_d linter.
  {
    "mfussenegger/nvim-lint",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact", "tsx" },
    opts = {
      linters_by_ft = {
        javascript = { "eslint_d" },
        typescript = { "eslint_d" },
        javascriptreact = { "eslint_d" },
        typescriptreact = { "eslint_d" },
      },
    },
  },

  -- 4. NVIM-LSPCONFIG: Configures tsserver.
  {
    "neovim/nvim-lspconfig",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact", "tsx" },
    opts = {
      servers = {
        ts_ls = {
          -- typescript-language-server now uses ts_ls instead of tsserver.
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

  -- 5. TREESITTER: Installs the parsers.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "javascript", "typescript", "javascriptreact", "typescriptreact", "tsx" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "javascript", "typescript", "tsx" })
      end
    end,
  },
}
