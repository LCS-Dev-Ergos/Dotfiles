-- File: lua/plugins/treesitter.lua
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- Here only "generic" languages not covered elsewhere
      vim.list_extend(opts.ensure_installed, {
        "bash",
        "json",
        "yaml",
        "lua",
        "query",
      })
    end,
  },
}
