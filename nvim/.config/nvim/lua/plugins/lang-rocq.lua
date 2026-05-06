-- File: lua/plugins/lang-rocq.lua
-- Rocq (formerly Coq) - Interactive theorem prover.
-- Mason's coq-lsp package (0.1.8+8.19) is incompatible with OCaml 5.x / arm64.
return {
  -- 1. COQTAIL: Interactive proof stepping — goal display, step forward/back.
  {
    "whonore/Coqtail",
    ft = { "coq" },
    init = function()
      vim.g.coqtail_nomap = 1
    end,
    keys = {
      { "<leader>cc", "<cmd>CoqStart<cr>", ft = "coq", desc = "Rocq Start" },
      { "<leader>cq", "<cmd>CoqStop<cr>", ft = "coq", desc = "Rocq Stop" },
      { "<leader>cj", "<cmd>CoqNext<cr>", ft = "coq", desc = "Rocq Next" },
      { "<leader>ck", "<cmd>CoqUndo<cr>", ft = "coq", desc = "Rocq Undo" },
      -- <leader>cl is taken by LazyVim (LSP info), use capital L here.
      { "<leader>cL", "<cmd>CoqToLine<cr>", ft = "coq", desc = "Rocq To Line" },
      { "<leader>cG", "<cmd>CoqJumpToEnd<cr>", ft = "coq", desc = "Rocq Jump to End" },
    },
  },

  -- 2. NVIM-LSPCONFIG: Wire up coq-lsp if it is available on PATH.
  {
    "neovim/nvim-lspconfig",
    ft = { "coq" },
    opts = {
      servers = {
        -- mason = false: coq-lsp is installed via opam, not Mason.
        -- mason-lspconfig will skip auto-installation and use the PATH binary.
        coq_lsp = { mason = false },
      },
    },
  },

  -- 3. TREESITTER: Coq parser for syntax highlighting.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "coq" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "coq" })
      end
    end,
  },
}
