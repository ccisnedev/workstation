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
--  3b. What the file explorer can do with the file under the cursor
--
--  The tree already opens, renames, creates and deletes. What it has no
--  opinion about is the rest of the desktop: the clipboard the agent pane
--  pastes from, the program that owns a PDF, the file manager. These four
--  commands are that bridge, and each one says what it did, because a key
--  that acts silently reads as a key that did nothing.
-- ----------------------------------------------------------------------------
local function node_path(state)
  local node = state.tree:get_node()
  if node == nil then
    vim.notify("nothing is selected in the tree", vim.log.levels.WARN)
    return nil
  end
  return node.path
end

local tree_commands = {

  -- The path as text. This is what the agent pane wants: paste it with
  -- Ctrl+Shift+V and the agent is told which file you mean.
  workstation_copy_path = function(state)
    local path = node_path(state)
    if path == nil then return end
    vim.fn.setreg("+", path)
    vim.notify("path copied: " .. path)
  end,

  -- The file itself, as a file, so it can be pasted into Explorer or into
  -- another application. Windows only: no other desktop has one way to put a
  -- file on the clipboard, and picking one per desktop is not this file's
  -- job. Elsewhere the path is copied and the difference is said out loud.
  workstation_copy_file = function(state)
    local path = node_path(state)
    if path == nil then return end
    if vim.fn.has("win32") == 0 then
      vim.fn.setreg("+", path)
      vim.notify("copying the file itself is Windows only here; the path was copied instead",
        vim.log.levels.WARN)
      return
    end
    -- Windows PowerShell, not pwsh, and single threaded on purpose. Putting a
    -- file rather than text on the clipboard is `Set-Clipboard -LiteralPath`,
    -- which exists only in Windows PowerShell 5.1, and the clipboard API it
    -- calls requires an STA thread.
    local quoted = "'" .. path:gsub("'", "''") .. "'"
    vim.system(
      { "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command",
        "Set-Clipboard -LiteralPath " .. quoted },
      { text = true },
      function(done)
        vim.schedule(function()
          if done.code == 0 then
            vim.notify("file copied: " .. path)
          else
            vim.notify("could not copy the file: " .. (done.stderr or ""), vim.log.levels.ERROR)
          end
        end)
      end)
  end,

  -- Whatever the desktop opens it with: a PDF in the PDF reader, an image in
  -- the image viewer. vim.ui.open picks the platform's opener.
  workstation_open_external = function(state)
    local path = node_path(state)
    if path == nil then return end
    vim.ui.open(path)
    vim.notify("opened with the default program: " .. path)
  end,

  -- The folder it lives in, in the system file manager, with the file
  -- selected where the platform can do that. Explorer wants one argument
  -- with the path glued to the switch, and backslashes.
  workstation_reveal_in_manager = function(state)
    local path = node_path(state)
    if path == nil then return end
    if vim.fn.has("win32") == 1 then
      vim.system({ "explorer.exe", "/select," .. path:gsub("/", "\\") })
    else
      vim.ui.open(vim.fs.dirname(path))
    end
    vim.notify("opened the containing folder of: " .. path)
  end,
}



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
        mappings = {
          ["Y"]  = "workstation_copy_path",
          ["gy"] = "workstation_copy_file",
          ["gx"] = "workstation_open_external",
          ["gr"] = "workstation_reveal_in_manager",
        },
      },
      commands = tree_commands,
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

  -- The changed files, side by side against git: the panel you go to when
  -- the agent says it edited six files and you want to see the six.
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
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

-- Reviewing what the agent changed. <leader>d is the whole working tree
-- against git, one pane per side; <leader>D closes it again. The hunk keys
-- are the same review one file at a time, without leaving the buffer.
map("n", "<leader>d", "<cmd>DiffviewOpen<cr>",
  { desc = "Review every change against git" })

map("n", "<leader>D", "<cmd>DiffviewClose<cr>",
  { desc = "Close the review" })

map("n", "<leader>h", "<cmd>DiffviewFileHistory %<cr>",
  { desc = "The history of this file" })

map("n", "]c", "<cmd>Gitsigns next_hunk<cr>",
  { desc = "Go to the next change in this file" })

map("n", "[c", "<cmd>Gitsigns prev_hunk<cr>",
  { desc = "Go to the previous change in this file" })

map("n", "<leader>p", "<cmd>Gitsigns preview_hunk<cr>",
  { desc = "Show the change under the cursor" })

map("n", "<leader>u", "<cmd>Gitsigns reset_hunk<cr>",
  { desc = "Undo the change under the cursor" })

map("n", "<leader>l", "<cmd>Gitsigns blame_line<cr>",
  { desc = "Who last changed this line" })


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
