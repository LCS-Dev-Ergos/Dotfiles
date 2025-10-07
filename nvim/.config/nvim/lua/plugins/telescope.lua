return {
  {
    "nvim-telescope/telescope.nvim",
    opts = {
      defaults = {
        layout_strategy = "horizontal",
        layout_config = { prompt_position = "top" },
        sorting_strategy = "ascending",
        winblend = 0,
      },
    },
    -- Here you can also add keymaps
    keys = {
      -- Example: keymap to search in LazyVim configuration files
      {
        "<leader>fp",
        function()
          require("telescope.builtin").find_files { cwd = require("lazy.core.config").options.root }
        end,
        desc = "Find Plugin File",
      },
    },
  },
}
