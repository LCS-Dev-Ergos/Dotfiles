-- =====-----------------------------------------------------------------=====
-- JULIA
--
-- Mathematical Unicode input uses cmp-latex-symbols through blink.compat,
-- keeping completion in LazyVim's existing Blink menu.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. BLINK.CMP: Adds LaTeX-style abbreviations for mathematical Unicode.
  {
    "saghen/blink.cmp",
    dependencies = { "kdheepak/cmp-latex-symbols", "saghen/blink.compat" },
    opts = {
      sources = {
        compat = { "latex_symbols" },
        providers = {
          latex_symbols = {
            kind = "LatexSymbols",
            async = true,
            opts = { strategy = 0 },
          },
        },
      },
    },
  },
}
