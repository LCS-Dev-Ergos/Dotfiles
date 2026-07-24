-- =====-----------------------------------------------------------------=====
-- TREESITTER (GENERIC PARSERS)
--
-- Parsers for generic config/utility filetypes that don't have their own
-- lang-*.lua file. Language-specific parsers are ensure_installed from the
-- respective lang-*.lua file instead.
-- =====-----------------------------------------------------------------=====

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