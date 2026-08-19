-- ============================================================================
--  Neovim configuration for the workstation
--
--  Lives in the repository at code/assets/neovim/init.lua
--
--  This configuration is NEVER installed over the user's own Neovim setup.
--  It is deployed under its own Neovim application name, "workstation", and is
--  only loaded when NVIM_APPNAME is set to that value:
--
--      Windows   %LOCALAPPDATA%\workstation
--      Linux     $XDG_CONFIG_HOME/workstation   (default ~/.config/workstation)
--
--  Running plain `nvim` keeps reading the user's own configuration, untouched.
--  See docs/adr/0002-the-workstation-never-owns-what-it-did-not-create.md
-- ============================================================================


-- ----------------------------------------------------------------------------
--  1. Leader key
--     Must be defined before any plugin loads. Here it is the space bar.
-- ----------------------------------------------------------------------------
vim.g.mapleader = " "
vim.g.maplocalleader = " "


-- ----------------------------------------------------------------------------
--  2. Editor options
-- ----------------------------------------------------------------------------
vim.opt.number = true                    -- Show line numbers
vim.opt.relativenumber = false           -- Absolute numbering, not relative
vim.opt.mouse = "a"                      -- Mouse enabled in every mode
vim.opt.mousemodel = "popup"             -- Right click opens a context menu
vim.opt.termguicolors = true             -- 24-bit colour
vim.opt.cursorline = true                -- Highlight the cursor line
vim.opt.signcolumn = "yes"               -- Always reserve the sign column
vim.opt.wrap = false                     -- Do not wrap long lines
vim.opt.scrolloff = 8                    -- Keep 8 lines of context when scrolling

vim.opt.expandtab = true                 -- Insert spaces instead of tabs
vim.opt.shiftwidth = 2                   -- Indentation width
vim.opt.tabstop = 2                      -- Visual width of a tab
vim.opt.smartindent = true               -- Automatic indentation

vim.opt.ignorecase = true                -- Case-insensitive search
vim.opt.smartcase = true                 -- ...unless the pattern has a capital
vim.opt.incsearch = true                 -- Show matches while typing
vim.opt.hlsearch = true                  -- Highlight every match

vim.opt.splitright = true                -- Vertical splits open to the right
vim.opt.splitbelow = true                -- Horizontal splits open below

vim.opt.undofile = true                  -- Persistent undo history
vim.opt.swapfile = false                 -- No swap files
vim.opt.updatetime = 250                 -- Milliseconds before refreshing
vim.opt.clipboard = "unnamedplus"        -- Share the system clipboard


-- ----------------------------------------------------------------------------
--  3. Bootstrap the lazy.nvim plugin manager
--     Cloned from GitHub on first start if it is not present yet.
-- ----------------------------------------------------------------------------
local plugin_manager_path = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(plugin_manager_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    plugin_manager_path,
  })
end

vim.opt.runtimepath:prepend(plugin_manager_path)


-- ----------------------------------------------------------------------------
--  4. Plugins
--
--  The exact revision of every plugin is pinned in lazy-lock.json, which is
--  committed on purpose: it is what makes a second machine resolve the same
--  versions instead of whatever happens to be current that day.
-- ----------------------------------------------------------------------------
require("lazy").setup({

  -- Colour scheme
  {
    "folke/tokyonight.nvim",
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tokyonight-night")
    end,
  },

  -- Status line
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        theme = "tokyonight",
        globalstatus = true,
      },
    },
  },

  -- File explorer: the tree on the left
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    lazy = false,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    opts = {
      close_if_last_window = true,
      enable_git_status = true,
      enable_diagnostics = true,
      window = {
        position = "left",
        width = 34,
      },
      filesystem = {
        follow_current_file = { enabled = true },
        use_libuv_file_watcher = true,
        filtered_items = {
          visible = true,
          hide_dotfiles = false,
          hide_gitignored = true,
        },
      },
    },
  },

  -- File and text finder
  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {},
  },

  -- Syntax highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "lua", "vim", "vimdoc", "javascript", "typescript",
          "tsx", "html", "css", "json", "markdown", "bash", "python", "dart",
        },
        auto_install = true,
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
  },

  -- Git markers in the left gutter
  {
    "lewis6991/gitsigns.nvim",
    opts = {},
  },

}, {
  -- Options for the plugin manager itself
  ui = { border = "rounded" },
  checker = { enabled = false },
})


-- ----------------------------------------------------------------------------
--  5. Key mappings
--     <leader> is the space bar.
-- ----------------------------------------------------------------------------
local map = vim.keymap.set

map("n", "<leader>e", "<cmd>Neotree toggle<cr>",
  { desc = "Toggle the file explorer" })

map("n", "<leader>f", "<cmd>Telescope find_files<cr>",
  { desc = "Find a file by name" })

map("n", "<leader>g", "<cmd>Telescope live_grep<cr>",
  { desc = "Search for text across the project" })

map("n", "<leader>b", "<cmd>Telescope buffers<cr>",
  { desc = "List the open buffers" })

map("n", "<C-s>", "<cmd>write<cr>",
  { desc = "Save the current file" })

map("i", "<C-s>", "<Esc><cmd>write<cr>",
  { desc = "Save the current file from insert mode" })

map("n", "<Esc>", "<cmd>nohlsearch<cr>",
  { desc = "Clear the search highlight" })


-- ----------------------------------------------------------------------------
--  6. Open the file explorer on start
-- ----------------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimEnter", {
  desc = "Open the file tree when Neovim starts",
  callback = function()
    vim.cmd("Neotree show")
  end,
})
