-- File: lua/plugins/vim-tex.lua
-- LazyVim's lang.tex extra already loads vimtex; this file overrides settings.
return {
  {
    "lervag/vimtex",
    lazy = false,
    init = function()
      vim.g.vimtex_view_method = "zathura"
      vim.g.vimtex_compiler_method = "latexmk"
      -- Keep quickfix closed on warnings; open only on errors.
      vim.g.vimtex_quickfix_mode = 2
      vim.g.vimtex_quickfix_open_on_warning = 0
      -- Concealment: symbols and greek letters, not fractions/super-sub.
      vim.g.vimtex_syntax_conceal = {
        accents = 1,
        ligatures = 1,
        cites = 1,
        fancy = 1,
        greek = 1,
        math_bounds = 0,
        math_delimiters = 1,
        math_fracs = 0,
        math_super_sub = 0,
        math_symbols = 1,
        sections = 0,
        styles = 1,
      }
    end,
  },
}
