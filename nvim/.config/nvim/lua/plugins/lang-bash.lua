-- File: lua/plugins/lang-bash.lua

return {
    -- 1. MASON: Ensure that the LSP, formatter, and linter are installed.
    {
        "williamboman/mason.nvim",
        opts = function(_, opts)
            opts.ensure_installed = opts.ensure_installed or {}
            vim.list_extend(opts.ensure_installed, {
                "bash-language-server", -- LSP for diagnostics and completion
                "beautysh", -- The formatter you requested
                "shellcheck", -- One of the best linters for shell scripts
            })
        end,
    },

    -- 2. CONFORM.NVIM (Formatter): Use beautysh for shell files.
    {
        "stevearc/conform.nvim",
        opts = {
            formatters_by_ft = {
                -- Apply the formatter to bash, zsh, and generic sh
                bash = { "beautysh" },
                zsh = { "beautysh" },
                sh = { "beautysh" },
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

    -- 4. TREESITTER: Ensure that the parser for bash is installed.
    {
        "nvim-treesitter/nvim-treesitter",
        opts = function(_, opts)
            if type(opts.ensure_installed) == "table" then
                vim.list_extend(opts.ensure_installed, { "bash" })
            end
        end,
    },
        -- Add this specification to configure indentation.
    {
        "nvim-treesitter/nvim-treesitter",
        ft = { "bash", "zsh", "sh" }, -- Run only for these filetypes
        config = function()
            -- Set options only for the current buffer when
            -- the filetype is one of those specified.
            vim.bo.expandtab = true
            vim.bo.shiftwidth = 2
            vim.bo.tabstop = 2
        end,
    },
}