-- =====-----------------------------------------------------------------=====
-- SNACKS (FOLKE/SNACKS.NVIM)
--
-- lazyvim.plugins.extras.editor.snacks_picker and .snacks_explorer (enabled
-- in lazyvim.json) already provide the picker/explorer keymaps: the full
-- <leader>f*/<leader>g*/<leader>s* menus, LSP navigation through Snacks, and
-- the todo-comments/trouble/flash integrations. This file only turns on the
-- remaining modules those extras don't touch, and keeps the keymaps that
-- have no other source (zen, bufdelete, lazygit, terminal, the plugin-file
-- finder). The dashboard stays off: ui.alpha is this setup's start screen.
-- =====-----------------------------------------------------------------=====

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    dashboard = { enabled = false },

    bigfile = { enabled = true },
    bufdelete = { enabled = true },
    explorer = { enabled = true },
    indent = { enabled = true },
    input = { enabled = true },
    notifier = { enabled = true, timeout = 3000 },
    picker = { enabled = true },
    quickfile = { enabled = true },
    scope = { enabled = true },
    scroll = { enabled = true },
    statuscolumn = { enabled = true },
    lazygit = { enabled = true },
    terminal = { enabled = true },
    words = { enabled = true },
    zen = { enabled = true },
  },
  keys = {
    { "<leader>z", function() require("snacks").zen() end, desc = "Toggle Zen Mode" },
    { "<leader>bd", function() require("snacks").bufdelete() end, desc = "Delete Buffer" },
    { "<leader>gg", function() require("snacks").lazygit() end, desc = "Lazygit" },
    { "<leader>T", function() require("snacks").terminal() end, desc = "Toggle Terminal" },
    {
      "<leader>fP",
      function()
        require("snacks").picker.files({ cwd = require("lazy.core.config").options.root })
      end,
      desc = "Find Plugin File",
    },
  },
}
