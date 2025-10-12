-- File: lua/plugins/lang-ocaml.lua
return {
  -- 1. MASON: Installs ocaml-lsp (LSP) and ocamlformat (formatter).
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "ocaml-lsp", "ocamlformat" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses ocamlformat.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { ocaml = { "ocamlformat" } },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures ocaml-lsp.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ocaml_lsp = {},
      },
    },
  },

  -- 4. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "ocaml" })
      end
    end,
  },
}
