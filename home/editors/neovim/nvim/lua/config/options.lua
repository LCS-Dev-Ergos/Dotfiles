-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Disable unused providers to suppress checkhealth warnings.
vim.g.loaded_perl_provider = 0

-- Python3 provider: dedicated venv at ~/.venv/nvim, isolated from pyenv and pip
-- restrictions. Setup (once): python3 -m venv ~/.venv/nvim && ~/.venv/nvim/bin/pip install pynvim
vim.g.python3_host_prog = vim.fn.expand("~/.venv/nvim/bin/python3")

-- Display options
vim.opt.winbar = "%=%m %f"
vim.opt.wrap = true

-- Disable automatic formatting globally
-- Use vim.g.autoformat (LazyVim standard) instead of vim.g.format_on_save
vim.g.autoformat = false

-- OCaml: Add ocp-indent to runtime path, querying opam for the actual location.
local ocp_share = vim.fn.trim(vim.fn.system("opam var ocp-indent:share 2>/dev/null"))
if vim.v.shell_error == 0 and ocp_share ~= "" then
  local ocp_vim = ocp_share .. "/vim"
  if vim.fn.isdirectory(ocp_vim) == 1 then
    vim.opt.rtp:prepend(ocp_vim)
  end
end

vim.filetype.add({ extension = { tpp = "cpp" } })