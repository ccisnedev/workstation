-- ============================================================================
--  WezTerm configuration for the workstation
--
--  Lives in the repository at code/assets/wezterm/wezterm.lua
--
--  This file is NEVER installed over the user's own WezTerm configuration.
--  Start-Workstation passes it explicitly with `wezterm --config-file <path>`,
--  so a plain `wezterm` still reads whatever the user already had.
--  See docs/adr/0002-the-workstation-never-owns-what-it-did-not-create.md
--
--  WezTerm is what replaces tmux here. It carries its own pane multiplexer,
--  written in Rust, native on Windows, Linux and macOS, configured in Lua.
-- ============================================================================

local wezterm = require("wezterm")
local mux     = wezterm.mux
local action  = wezterm.action

local config = wezterm.config_builder()


-- ----------------------------------------------------------------------------
--  Layout geometry
--  Change these two numbers to re-proportion the workspace.
-- ----------------------------------------------------------------------------
local AGENT_PANE_WIDTH   = 0.38   -- Fraction of the window width, on the right
local TERMINAL_PANE_HEIGHT = 0.22 -- Fraction of the left column, at the bottom

--  The Neovim application name this workstation deploys under. It must match
--  the link target that Install-Workstation creates.
local NEOVIM_APPLICATION_NAME = "workstation"


-- ----------------------------------------------------------------------------
--  Platform
-- ----------------------------------------------------------------------------
local is_windows = wezterm.target_triple:find("windows") ~= nil


-- ----------------------------------------------------------------------------
--  1. Default shell
--     On Windows, PowerShell 7. On Linux and macOS, whatever login shell the
--     user already has, which WezTerm resolves on its own.
-- ----------------------------------------------------------------------------
if is_windows then
  config.default_prog = { "pwsh.exe", "-NoLogo" }
end


-- ----------------------------------------------------------------------------
--  2. Appearance
-- ----------------------------------------------------------------------------
config.color_scheme = "Tokyo Night"
config.font = wezterm.font_with_fallback({
  "JetBrains Mono",          -- Bundled with WezTerm
  "Symbols Nerd Font Mono",  -- Icons for the file explorer
  "Consolas",
  "DejaVu Sans Mono",
})
config.font_size = 11.0
config.line_height = 1.1

config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
config.window_decorations = "RESIZE"
config.window_close_confirmation = "NeverPrompt"
config.enable_scroll_bar = false
config.scrollback_lines = 10000

config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false

-- The unfocused pane is dimmed, so it is obvious where the cursor is
config.inactive_pane_hsb = {
  saturation = 0.85,
  brightness = 0.65,
}


-- ----------------------------------------------------------------------------
--  3. Mouse
--     WezTerm already enables the mouse: clicking a pane focuses it, dragging
--     the divider resizes, and the wheel scrolls the scrollback. The only
--     addition here is Ctrl + click to open links.
-- ----------------------------------------------------------------------------
config.mouse_bindings = {
  {
    event = { Up = { streak = 1, button = "Left" } },
    mods = "CTRL",
    action = action.OpenLinkAtMouseCursor,
  },
}


-- ----------------------------------------------------------------------------
--  4. Pane key bindings
--     Control + Shift, chosen so nothing collides with Neovim or the agents.
-- ----------------------------------------------------------------------------
config.keys = {
  -- Move between panes
  { key = "LeftArrow",  mods = "CTRL|SHIFT", action = action.ActivatePaneDirection("Left")  },
  { key = "RightArrow", mods = "CTRL|SHIFT", action = action.ActivatePaneDirection("Right") },
  { key = "UpArrow",    mods = "CTRL|SHIFT", action = action.ActivatePaneDirection("Up")    },
  { key = "DownArrow",  mods = "CTRL|SHIFT", action = action.ActivatePaneDirection("Down")  },

  -- Split the current pane
  { key = "d", mods = "CTRL|SHIFT", action = action.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  { key = "e", mods = "CTRL|SHIFT", action = action.SplitVertical({ domain = "CurrentPaneDomain" })   },

  -- Zoom a pane to the full window and back
  { key = "z", mods = "CTRL|SHIFT", action = action.TogglePaneZoomState },

  -- Close the current pane
  { key = "w", mods = "CTRL|SHIFT", action = action.CloseCurrentPane({ confirm = true }) },

  -- Resize from the keyboard as well as the mouse
  { key = "H", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Left",  3 }) },
  { key = "L", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Right", 3 }) },
  { key = "K", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Up",    3 }) },
  { key = "J", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Down",  3 }) },
}


-- ----------------------------------------------------------------------------
--  5. Command builders
--
--  Both panes keep their shell alive after the program exits, so quitting
--  Neovim or the agent leaves a usable prompt instead of closing the pane.
-- ----------------------------------------------------------------------------

--- Runs `command` and then hands the pane back to an interactive shell.
local function run_then_keep_shell(command)
  if is_windows then
    return { "pwsh.exe", "-NoLogo", "-NoExit", "-Command", command }
  end
  return { "/bin/bash", "-lc", command .. "; exec /bin/bash" }
end

--- Maximises the window, once it is safe to do so.
---
--- Calling maximize() straight from gui-startup races the compositor on
--- Wayland: the surface is still at its default size while the maximised state
--- has already been configured, and the resulting xdg_wm_base protocol error
--- kills the window outright. It is intermittent, so it looks like a flake
--- until it is not. Deferring past the first buffer commit avoids the race,
--- and pcall keeps any remaining failure cosmetic rather than fatal.
local function maximize_when_ready(window)
  wezterm.time.call_after(0.3, function()
    pcall(function() window:gui_window():maximize() end)
  end)
end

--- Runs Neovim with the workstation application name, without touching the
--- user's own Neovim configuration.
local function editor_command()
  if is_windows then
    return run_then_keep_shell(
      '$env:NVIM_APPNAME = "' .. NEOVIM_APPLICATION_NAME .. '"; nvim .')
  end
  return run_then_keep_shell(
    "NVIM_APPNAME=" .. NEOVIM_APPLICATION_NAME .. " nvim .")
end


-- ----------------------------------------------------------------------------
--  6. The workstation layout
--
--  Start-Workstation sets two environment variables before launching WezTerm:
--
--      WORKSTATION_AGENT       claude | codex | agy | opencode
--      WORKSTATION_DIRECTORY   the project directory
--
--  When both are present, this builds the three-pane workspace:
--
--      +------------------------------+-------------------+
--      |  Neovim                      |                   |
--      |  file tree + current file    |  AI agent         |
--      |                              |                   |
--      +------------------------------+                   |
--      |  Shell                       |                   |
--      +------------------------------+-------------------+
--
--  When they are absent, WezTerm opens an ordinary window, so this file is
--  still usable as a plain configuration.
-- ----------------------------------------------------------------------------
wezterm.on("gui-startup", function(spawn_command)

  local agent             = os.getenv("WORKSTATION_AGENT")
  local project_directory = os.getenv("WORKSTATION_DIRECTORY")

  -- Case 1: ordinary start, no layout requested
  if agent == nil or agent == "" or project_directory == nil or project_directory == "" then
    local _, _, window = mux.spawn_window(spawn_command or {})
    maximize_when_ready(window)
    return
  end

  -- Case 2: the workstation layout

  -- Pane 1, left: Neovim over the project directory
  local _, editor_pane, window = mux.spawn_window({
    cwd  = project_directory,
    args = editor_command(),
  })

  maximize_when_ready(window)

  -- Pane 2, right: the AI agent
  editor_pane:split({
    direction = "Right",
    size      = AGENT_PANE_WIDTH,
    cwd       = project_directory,
    args      = run_then_keep_shell(agent),
  })

  -- Pane 3, bottom left: a free shell to run the project
  editor_pane:split({
    direction = "Bottom",
    size      = TERMINAL_PANE_HEIGHT,
    cwd       = project_directory,
  })

  -- Leave the focus on the editor
  editor_pane:activate()
end)


return config
