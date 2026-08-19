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
--  Nothing in this file is taste. Every colour, size and proportion comes from
--  the preferences, resolved by Install-Workstation and compiled into a Lua
--  table this file loads. What stays here is the shape: three panes, what runs
--  in each, and how they are wired together.
--  See docs/adr/0005-architecture-and-preference-are-different-things.md
--
--  WezTerm is what replaces tmux here. It carries its own pane multiplexer,
--  written in Rust, native on Windows, Linux and macOS, configured in Lua.
-- ============================================================================

local wezterm = require("wezterm")
local mux     = wezterm.mux
local action  = wezterm.action

local config = wezterm.config_builder()


-- ----------------------------------------------------------------------------
--  Preferences
--
--  Install-Workstation compiles the resolved preferences into a Lua file and
--  points WORKSTATION_PREFERENCES at it. The table below is the fallback for
--  when that has not happened yet — a fresh clone, or a `wezterm --config-file`
--  run by hand — so the workspace always opens, just with shipped values.
--
--  These defaults must stay in step with code/powershell/Workstation/Preferences.psd1.
-- ----------------------------------------------------------------------------
local DEFAULT_PREFERENCES = {
  layout = {
    agent_pane_width     = 0.38,
    terminal_pane_height = 0.22,
    maximize_on_start    = true,
    dim_inactive_panes   = true,
  },
  terminal = {
    color_scheme     = "Tokyo Night",
    font_family      = "JetBrains Mono",
    font_size        = 11.0,
    line_height      = 1.1,
    window_padding   = 8,
    scrollback_lines = 10000,
  },
}

--- Loads the compiled preferences, falling back section by section.
---
--- A partial or stale generated file is merged over the defaults rather than
--- replacing them, so a preference added to the repository after the last
--- apply still has a value instead of becoming nil halfway through startup.
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

local preferences = load_preferences()
local layout      = preferences.layout
local terminal    = preferences.terminal


-- ----------------------------------------------------------------------------
--  Architecture: the Neovim application name this workstation deploys under.
--  Not a preference. It must match the link target Install-Workstation creates,
--  and changing it in one place without the other breaks the deployment.
-- ----------------------------------------------------------------------------
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
--  2. Appearance, entirely from preferences
-- ----------------------------------------------------------------------------
config.color_scheme = terminal.color_scheme
config.font = wezterm.font_with_fallback({
  terminal.font_family,
  "Symbols Nerd Font Mono",  -- Icons for the file explorer
  "Consolas",
  "DejaVu Sans Mono",
})
config.font_size   = terminal.font_size
config.line_height = terminal.line_height

config.window_padding = {
  left   = terminal.window_padding,
  right  = terminal.window_padding,
  top    = terminal.window_padding,
  bottom = terminal.window_padding,
}
config.window_decorations = "RESIZE"
config.window_close_confirmation = "NeverPrompt"
config.enable_scroll_bar = false
config.scrollback_lines = terminal.scrollback_lines

config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false

if layout.dim_inactive_panes then
  config.inactive_pane_hsb = { saturation = 0.85, brightness = 0.65 }
end


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
  if not layout.maximize_on_start then return end
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
--  Start-Workstation sets these environment variables before launching WezTerm:
--
--      WORKSTATION_AGENT        claude | codex | agy | opencode
--      WORKSTATION_DIRECTORY    the project directory
--      WORKSTATION_PREFERENCES  the compiled preferences, read above
--
--  When the first two are present, this builds the three-pane workspace:
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
    size      = layout.agent_pane_width,
    cwd       = project_directory,
    args      = run_then_keep_shell(agent),
  })

  -- Pane 3, bottom left: a free shell to run the project
  editor_pane:split({
    direction = "Bottom",
    size      = layout.terminal_pane_height,
    cwd       = project_directory,
  })

  -- Leave the focus on the editor
  editor_pane:activate()
end)


return config
