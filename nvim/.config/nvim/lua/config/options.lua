-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

vim.opt.winbar = "%=%m %f"
vim.opt.wrap = true

-- Personal Keymaps
-- navigate within insert mode (with remaps)
-- Abilita la navigazione con HJKL in modalità di inserimento
vim.api.nvim_set_keymap("i", "<C-h>", "<Left>", { noremap = true })
vim.api.nvim_set_keymap("i", "<C-j>", "<Down>", { noremap = true })
vim.api.nvim_set_keymap("i", "<C-k>", "<Up>", { noremap = true })
vim.api.nvim_set_keymap("i", "<C-l>", "<Right>", { noremap = true })

-- Disabilita il formattatore automatico all'apertura di un file
vim.g.format_on_save = false

-- Formattazione automatica dei file C e C++
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = { "*.c", "*.cpp" },
  callback = function() require("conform").format() end,
})

-- Aggiunge ocp-indent per l'indentazione di OCaml
vim.opt.rtp:prepend("/Users/lcs-dev/.opam/ocaml-compiler/share/ocp-indent/vim")
