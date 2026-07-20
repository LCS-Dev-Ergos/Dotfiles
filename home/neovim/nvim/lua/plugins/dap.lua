-- File: lua/plugins/dap.lua
-- LazyVim's dap.core extra provides nvim-dap, dap-ui, dap-virtual-text, and
-- mason-nvim-dap with automatic_installation=true. This file wires up the
-- adapters that are already installed via Mason in the lang-*.lua files.

-- Filetypes that belong to DAP UI windows, not to source files.
local dap_ui_filetypes = {
  dapui_console = true,
  dapui_watches = true,
  dapui_stacks  = true,
  dapui_scopes  = true,
  dapui_breakpoints = true,
  ["dap-repl"]  = true,
}

-- Returns the first non-dapui window and its filetype, or nil.
local function find_source_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft  = vim.bo[buf].filetype
    if not dap_ui_filetypes[ft] and ft ~= "" then
      return win, ft
    end
  end
end

-- Smart continue: when no session is active and the current window is a dapui
-- window, switch focus to the source file first so dap picks the right ft.
local function smart_continue()
  local dap = require("dap")
  if dap.session() ~= nil then
    dap.continue()
    return
  end
  if dap_ui_filetypes[vim.bo.filetype] then
    local win = find_source_win()
    if win then
      vim.api.nvim_set_current_win(win)
    end
  end
  dap.continue()
end

return {
  -- Ensure codelldb is registered and auto-configured for C, C++, and Rust.
  -- Python is handled by LazyVim's lang.python extra.
  {
    "jay-babu/mason-nvim-dap.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "codelldb" })
    end,
  },

  {
    "mfussenegger/nvim-dap",
    keys = {
      -- Override LazyVim's default <F5> and <leader>dc with the smart version.
      { "<F5>",        smart_continue, desc = "DAP Continue" },
      { "<leader>dc",  smart_continue, desc = "DAP Continue" },
      -- Reload .vscode/launch.json after editing it without restarting Neovim.
      {
        "<leader>dL",
        function()
          local ok, vscode = pcall(require, "dap.ext.vscode")
          if ok then
            pcall(vscode.load_launchjs, nil, {
              codelldb = { "c", "cpp", "rust" },
              python   = { "python" },
            })
            vim.notify("launch.json reloaded", vim.log.levels.INFO)
          end
        end,
        desc = "DAP reload launch.json",
      },
    },
  },
}
