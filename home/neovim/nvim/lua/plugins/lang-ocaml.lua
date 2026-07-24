-- =====-----------------------------------------------------------------=====
-- OCAML
--
-- ocaml-lsp and ocamlformat come from opam (`opam install ocaml-lsp-server
-- ocamlformat`), on PATH via ~/.opam/default/bin -- the same toolchain Doom
-- Emacs' merlin/utop use. Neither tool needs Mason.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. CONFORM.NVIM (Formatter): Uses ocamlformat.
  {
    "stevearc/conform.nvim",
    ft = { "ocaml" },
    opts = {
      formatters_by_ft = { ocaml = { "ocamlformat" } },
    },
  },

  -- 2. NVIM-LSPCONFIG: Configures ocaml-lsp.
  {
    "neovim/nvim-lspconfig",
    ft = { "ocaml" },
    opts = {
      servers = {
        ocaml_lsp = {
          mason = false,
        },
      },
    },
  },

  -- 3. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "ocaml" },
    opts = require("lang_util").treesitter_ensure({ "ocaml" }),
  },
}
