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
--
--  Nothing in this file is taste. The colour scheme, the leader key, the width
--  of the file tree and the rest come from the preferences, resolved by
--  Install-Workstation and compiled into a Lua table this file loads.
--  See docs/adr/0005-architecture-and-preference-are-different-things.md
-- ============================================================================


-- ----------------------------------------------------------------------------
--  0. Preferences
--
--  Loaded first, because the leader key has to be set before any plugin.
--  The table below is the fallback for when nothing has been compiled yet, so
--  the editor always opens, just with shipped values.
--
--  These defaults must stay in step with code/powershell/Workstation/Preferences.psd1.
-- ----------------------------------------------------------------------------
local DEFAULT_PREFERENCES = {
  editor = {
    color_scheme            = "tokyonight-night",
    leader_key              = " ",
    relative_number         = false,
    tab_width               = 2,
    file_tree_width         = 34,
    file_tree_position      = "left",
    open_file_tree_on_start = true,
  },
}

--- Loads the compiled preferences, falling back section by section.
local function load_preferences()
  local resolved = {}
  for section, values in pairs(DEFAULT_PREFERENCES) do
    resolved[section] = {}
    for key, value in pairs(values) do resolved[section][key] = value end
  end

  local path = os.getenv("WORKSTATION_PREFERENCES")
  if path == nil or path == "" then return resolved end

  local chunk = loadfile(path)
  if chunk == nil then return resolved end

  local ok, loaded = pcall(chunk)
  if not ok or type(loaded) ~= "table" then return resolved end

  for section, values in pairs(loaded) do
    if type(values) == "table" and resolved[section] ~= nil then
      for key, value in pairs(values) do resolved[section][key] = value end
    end
  end
  return resolved
end

local editor = load_preferences().editor


-- ----------------------------------------------------------------------------
--  1. Leader key
--     Must be defined before any plugin loads.
-- ----------------------------------------------------------------------------
vim.g.mapleader = editor.leader_key
vim.g.maplocalleader = editor.leader_key


-- ----------------------------------------------------------------------------
--  2. Editor options
-- ----------------------------------------------------------------------------
vim.opt.number = true                            -- Show line numbers
vim.opt.relativenumber = editor.relative_number  -- Preference
vim.opt.mouse = "a"                              -- Mouse enabled in every mode
vim.opt.mousemodel = "popup"                     -- Right click opens a menu
vim.opt.termguicolors = true                     -- 24-bit colour
vim.opt.cursorline = true                        -- Highlight the cursor line
vim.opt.signcolumn = "yes"                       -- Always reserve the column
vim.opt.wrap = false                             -- Do not wrap long lines
vim.opt.scrolloff = 8                            -- Context kept when scrolling

vim.opt.expandtab = true                         -- Spaces instead of tabs
vim.opt.shiftwidth = editor.tab_width            -- Preference
vim.opt.tabstop = editor.tab_width               -- Preference
vim.opt.smartindent = true                       -- Automatic indentation

vim.opt.ignorecase = true                        -- Case-insensitive search
vim.opt.smartcase = true                         -- ...unless it has a capital
vim.opt.incsearch = true                         -- Show matches while typing
vim.opt.hlsearch = true                          -- Highlight every match

vim.opt.splitright = true                        -- Vertical splits to the right
vim.opt.splitbelow = true                        -- Horizontal splits below

vim.opt.undofile = true                          -- Persistent undo history
vim.opt.swapfile = false                         -- No swap files
vim.opt.updatetime = 250                         -- Milliseconds before refresh
vim.opt.clipboard = "unnamedplus"                -- Share the system clipboard


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

  -- Colour schemes. Both are installed so the preference can name either
  -- without a reinstall; only the one preferred is applied.
  { "folke/tokyonight.nvim", priority = 1000, lazy = false },
  { "catppuccin/nvim", name = "catppuccin", priority = 1000, lazy = false },

  -- Status line
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { options = { globalstatus = true } },
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
        position = editor.file_tree_position,   -- Preference
        width    = editor.file_tree_width,      -- Preference
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
  --
  -- Pinned to master on purpose. The default branch is now `main`, a rewrite
  -- that removed `nvim-treesitter.configs` entirely, so an unpinned install
  -- fails at startup with "module 'nvim-treesitter.configs' not found" and
  -- leaves the editor with no highlighting at all. The failure is quiet: the
  -- rest of the configuration still loads, so it reads as working.
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
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
--  5. Colour scheme, from preferences
--
--  Applied after the plugins so the named scheme exists. A name no installed
--  plugin provides is reported rather than left as a silent default.
-- ----------------------------------------------------------------------------
local applied = pcall(vim.cmd.colorscheme, editor.color_scheme)
if not applied then
  vim.notify(
    "workstation: colour scheme '" .. tostring(editor.color_scheme) ..
    "' is not available; no plugin installed provides it",
    vim.log.levels.WARN)
end


-- ----------------------------------------------------------------------------
--  6. Key mappings
--     <leader> is whatever the preference set above.
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
--  7. Open the file explorer on start, if preferred
-- ----------------------------------------------------------------------------
if editor.open_file_tree_on_start then
  vim.api.nvim_create_autocmd("VimEnter", {
    desc = "Open the file tree when Neovim starts",
    callback = function()
      vim.cmd("Neotree show")
    end,
  })
end
