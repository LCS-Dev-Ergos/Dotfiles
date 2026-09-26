-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("n", "<leader>sx", function()
  require("snacks").picker.resume()
end, { noremap = true, silent = true, desc = "Resume" })

-- Navigation in insert mode using Ctrl+hjkl
vim.keymap.set("i", "<C-h>", "<Left>", { noremap = true, desc = "Move left" })
vim.keymap.set("i", "<C-j>", "<Down>", { noremap = true, desc = "Move down" })
vim.keymap.set("i", "<C-k>", "<Up>", { noremap = true, desc = "Move up" })
vim.keymap.set("i", "<C-l>", "<Right>", { noremap = true, desc = "Move right" })