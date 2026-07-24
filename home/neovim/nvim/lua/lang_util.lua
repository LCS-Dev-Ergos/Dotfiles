-- =====-----------------------------------------------------------------=====
-- File: lua/lang_util.lua
--
-- Shared boilerplate for the lang-*.lua plugin specs: extending or filtering
-- Mason's and Treesitter's `ensure_installed` lists is the same three lines
-- in nearly every one of them. Deliberately kept outside lua/plugins/, which
-- lazy.nvim scans and requires every file in to return a plugin spec.
-- =====-----------------------------------------------------------------=====

local M = {}

--- Extends Mason's ensure_installed list with `names`. Use as a
--- mason-org/mason.nvim `opts` function.
---@param names string[]
function M.mason_ensure(names)
  return function(_, opts)
    opts.ensure_installed = opts.ensure_installed or {}
    vim.list_extend(opts.ensure_installed, names)
  end
end

--- Removes `names` from Mason's ensure_installed list. Use as a
--- mason-org/mason.nvim `opts` function when a language's own toolchain
--- manager already provides a tool Mason would otherwise install.
---@param names string[]
function M.mason_exclude(names)
  local skip = {}
  for _, name in ipairs(names) do
    skip[name] = true
  end
  return function(_, opts)
    opts.ensure_installed = vim.tbl_filter(function(pkg)
      return not skip[pkg]
    end, opts.ensure_installed or {})
  end
end

--- Extends Treesitter's ensure_installed list with `parsers`. Use as an
--- nvim-treesitter/nvim-treesitter `opts` function.
---@param parsers string[]
function M.treesitter_ensure(parsers)
  return function(_, opts)
    if type(opts.ensure_installed) == "table" then
      vim.list_extend(opts.ensure_installed, parsers)
    end
  end
end

return M
