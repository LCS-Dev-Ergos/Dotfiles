-- File: lua/plugins/lang-bash.lua

return {
    -- 1. MASON: Ensure LSP, formatter, and linter are installed.
    {
        "mason-org/mason.nvim",
        opts = function(_, opts)
            opts.ensure_installed = opts.ensure_installed or {}
            vim.list_extend(opts.ensure_installed, {
                "bash-language-server", -- LSP for diagnostics and completion
                "shfmt", -- The new formatter
                "shellcheck", -- One of the best linters for shell scripts
            })
        end,
    },

    -- 2. CONFORM.NVIM (Formatter): Use shfmt for shell script files.
    {
        "stevearc/conform.nvim",
        opts = {
            formatters_by_ft = {
                -- Apply the formatter to bash, zsh, and generic sh
                bash = { "shfmt" },
                zsh = { "shfmt" },
                sh = { "shfmt" },
            },
        },
    },

    -- 3. NVIM-LSPCONFIG: Configure the language server (bashls).
    {
        "neovim/nvim-lspconfig",
        opts = {
            servers = {
                -- bashls serves both bash and other shell scripts
                bashls = {},
            },
        },
    },

    -- 4. TREESITTER: Ensure the parser for bash is installed.
    {
        "nvim-treesitter/nvim-treesitter",
        opts = function(_, opts)
            if type(opts.ensure_installed) == "table" then
                vim.list_extend(opts.ensure_installed, { "bash" })
            end
        end,
    },

    -- 5. SPECIFIC INDENTATION OPTIONS
    -- We add this specification to configure indentation.
    {
        "nvim-treesitter/nvim-treesitter", -- Use an existing plugin to hook the config
        ft = { "bash", "zsh", "sh" }, -- Execute only for these filetypes
        config = function()
            -- Set options for the current buffer when the filetype matches.
            vim.bo.expandtab = true -- Use spaces instead of the Tab character
            vim.bo.shiftwidth = 2 -- Width for an indentation level (e.g., for '>>')
            vim.bo.tabstop = 2 -- Visual representation of a Tab character
        end,
    },
}