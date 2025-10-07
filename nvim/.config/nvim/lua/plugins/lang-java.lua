-- File: lua/plugins/lang-java.lua
return {
  -- 1. MASON: Installa jdtls (LSP) e il debugger di Java
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "jdtls", "java-debug-adapter" })
    end,
  },

  -- 2. NVIM-LSPCONFIG: Configura jdtls. Questa configurazione è più complessa.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        jdtls = {},
      },
    },
  },

  -- 3. TREESITTER: Installa il parser
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "java" })
      end
    end,
  },
}
