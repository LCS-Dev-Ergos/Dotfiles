-- File: lua/plugins/treesitter.lua
-- Only generic languages not covered by specific lang-*.lua files

return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- Only add parsers for generic config files and other utilities
      -- Language-specific parsers are handled in their respective lang-*.lua files
      vim.list_extend(opts.ensure_installed, {
        "json",
        "yaml",
        "toml",
        "xml",
        "regex",
        "vim",
        "vimdoc",
      })
    end,
  },
}