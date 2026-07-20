return {
  "folke/tokyonight.nvim",
  lazy = false, -- Prevents lazy loading, the theme is loaded immediately
  priority = 1000, -- Assigns high priority to ensure it loads first
  opts = {
    style = "night", -- Choose your preferred style (storm, night, moon, day)
    transparent = false,
    terminal_colors = true,
  },
  config = function(_, opts)
    require("tokyonight").setup(opts) -- Apply options
    vim.cmd([[colorscheme tokyonight]]) -- Set the theme
  end,
}
