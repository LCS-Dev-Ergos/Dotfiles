-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Display options
vim.opt.winbar = "%=%m %f"
vim.opt.wrap = true

-- Disable automatic formatting globally
-- Use vim.g.autoformat (LazyVim standard) instead of vim.g.format_on_save
vim.g.autoformat = false

-- OCaml: Add ocp-indent to runtime path
-- NOTE: This path is system-specific. Adjust if needed on different machines.
local ocp_indent_path = vim.fn.expand("~/.opam/ocaml-compiler/share/ocp-indent/vim")
if vim.fn.isdirectory(ocp_indent_path) == 1 then
  vim.opt.rtp:prepend(ocp_indent_path)
end