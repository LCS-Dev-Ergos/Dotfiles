-- File: lua/plugins/lang-ocaml.lua
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "ocaml-lsp", "ocamlformat" })
    end,
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { ocaml = { "ocamlformat" } },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ocaml_lsp = {},
      },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "ocaml" })
      end
    end,
  },
}
