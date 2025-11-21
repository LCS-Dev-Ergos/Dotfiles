-- File: lua/plugins/lang-java.lua

return {
  -- 1. MASON: Installs jdtls (LSP) and the Java debugger.
  {
    "mason-org/mason.nvim",
    ft = { "java" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "jdtls", "java-debug-adapter" })
    end,
  },

  -- 2. NVIM-LSPCONFIG: Configures jdtls. This configuration is more complex.
  {
    "neovim/nvim-lspconfig",
    ft = { "java" },
    opts = {
      servers = {
        jdtls = {},
      },
    },
  },

  -- 3. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "java" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "java" })
      end
    end,
  },
}
