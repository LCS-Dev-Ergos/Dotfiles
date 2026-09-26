-- =====-----------------------------------------------------------------=====
-- LATEX (VIMTEX)
--
-- LazyVim's lang.tex extra already loads vimtex; this file overrides the
-- viewer, compiler, quickfix behavior, and syntax concealment settings.
--
-- home/ is shared between both hosts (see hosts/*/home.nix), so the viewer
-- must be picked per platform: Zathura is Linux-only, and on Darwin it's
-- neither installed nor the natural choice (checkhealth confirmed it's not
-- executable here) — Skim is already installed and is vimtex's documented
-- macOS backend, with the same forward/inverse SyncTeX search.
-- =====-----------------------------------------------------------------=====
return {
  {
    "lervag/vimtex",
    lazy = false,
    init = function()
      vim.g.vimtex_view_method = vim.loop.os_uname().sysname == "Darwin" and "skim" or "zathura"
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
