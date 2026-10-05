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
    window_padding     = 8,
    scrollback_lines   = 10000,
    window_decorations = "RESIZE",
  },
  -- Open: its keys are project names, so nothing is shipped in it. A pin
  -- written in the override file arrives here as ["name"] = "#rrggbb".
  project_colors = {
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

  -- Watched on purpose. WezTerm reloads on its own when this file or a
  -- required module changes, but a file read with loadfile is invisible to
  -- it, so an apply that recompiled the preferences reached only the windows
  -- opened afterwards. Now a pinned colour lands on the windows already open.
  wezterm.add_to_config_reload_watch_list(path)

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

local preferences    = load_preferences()
local layout         = preferences.layout
local terminal       = preferences.terminal
local project_colors = preferences.project_colors


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
--  Identity: which workstation this window is
--
--  Start-Workstation sets these environment variables before launching WezTerm:
--
--      WORKSTATION_AGENT        claude | codex | agy | opencode
--      WORKSTATION_DIRECTORY    the project directory
--      WORKSTATION_PREFERENCES  the compiled preferences, read above
--
--  When the first two are present this window is a workstation, and it is
--  named and coloured after its project so that four of them open at once can
--  be told apart from the taskbar, from Alt+Tab, and from across the room. The
--  derivation lives in identity.lua, beside this file, where the preference
--  suite can exercise it without a window. When they are absent, WezTerm opens
--  an ordinary window and this file is still usable as a plain configuration.
-- ----------------------------------------------------------------------------
local identity = dofile(wezterm.config_dir .. "/identity.lua")

local function requested_workstation()
  local agent             = os.getenv("WORKSTATION_AGENT")
  local project_directory = os.getenv("WORKSTATION_DIRECTORY")
  if agent == nil or agent == "" or project_directory == nil or project_directory == "" then
    return nil
  end
  return identity.describe(project_directory, agent, project_colors)
end

local workstation = requested_workstation()


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
config.window_decorations = terminal.window_decorations
config.window_close_confirmation = "NeverPrompt"
config.enable_scroll_bar = false
config.scrollback_lines = terminal.scrollback_lines

-- ----------------------------------------------------------------------------
--  The size the window is born at
--
--  Not taste, and deliberately not a preference: it is the floor that makes the
--  workspace able to open at all, and a value someone could lower to 80 would
--  bring back the defect it exists to prevent.
--
--  WezTerm's own default is 80x24. The agent pane is a fraction of that width,
--  so the agent was being handed a 30-column terminal — and opencode crashes
--  outright below 40 columns, measured, while claude, codex and antigravity
--  tolerate it. Its pane then execs into a plain shell and reads as perfectly
--  healthy, which is why this survived so long.
--
--  Maximising was supposed to make the window big, but it cannot be relied on
--  for this. It is deferred past the first buffer commit on purpose, because
--  calling it from gui-startup races the compositor and kills the window on
--  Wayland; under a software-rendered display it may never land at all. So the
--  window is born large and the maximise is left as the improvement it always
--  was, rather than the thing correctness rests on.
--
--  The narrowest pane must clear that measured floor with room to spare:
--  200 columns * 0.38 = 76 for the agent pane.
-- ----------------------------------------------------------------------------
config.initial_cols = 200
config.initial_rows = 50

config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false

if layout.dim_inactive_panes then
  config.inactive_pane_hsb = { saturation = 0.85, brightness = 0.65 }
end

-- ----------------------------------------------------------------------------
--  What a workstation window shows to be told apart
--
--  The title goes to the operating system, which is what the taskbar
--  thumbnails and Alt+Tab print. Left alone it is whatever the focused pane
--  last set, so it changed with every click and said the same thing in every
--  window. The accent is worn as a chip in the tab bar, which is kept visible
--  for that purpose, and as the colour of the pane dividers. The palette and
--  the derivation are architecture; which colour a given project gets is
--  taste, and can be pinned in the preferences.
-- ----------------------------------------------------------------------------
if workstation ~= nil then
  config.hide_tab_bar_if_only_one_tab   = false
  config.show_new_tab_button_in_tab_bar = false
  config.show_tab_index_in_tab_bar      = false
  -- WezTerm cuts a tab at 16 cells, which truncated the chip on the first
  -- real window. The chip is the whole point of the bar, so it gets the room
  -- a long project name needs.
  config.tab_max_width = 64
  config.colors = { split = workstation.accent }

  wezterm.on("format-window-title", function()
    return workstation.title
  end)

  wezterm.on("format-tab-title", function()
    return {
      { Background = { Color = workstation.accent } },
      { Foreground = { Color = workstation.text } },
      { Attribute  = { Intensity = "Bold" } },
      { Text = " " .. workstation.title .. " " },
    }
  end)


  -- Nothing is written to the right of the tab bar. What the agent knows
  -- about itself -- the model, the context used, the plan's limits -- was
  -- shown there for a while, and it was the same line the agent already
  -- prints at the bottom of its own pane, a few centimetres below. Two copies
  -- of one reading is one too many, and the copy further from the agent is
  -- the one to go. status.lua still ships and is still tested: it is the
  -- reader for the status files, which are written per project and are what a
  -- window that lists the open workstations would have to read.
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
--  4. Showing and hiding the panes
--
--  Ctrl+Shift+1, 2 and 3 show or hide the agent, the editor and the shell.
--  WezTerm has no way to hide a pane and put it back where it was, so a hidden
--  pane is drawn from what it does have: with all three visible the layout,
--  with two the hidden one shrunk to a cell, with one that pane zoomed. The
--  processes in a hidden pane keep running. Nothing is closed.
--  See docs/adr/0009-hiding-a-pane-is-drawn-as-a-collapse-or-a-zoom.md
--
--  The decision, and the sizes a decision asks for, are in panes.lua, where
--  the pane toggle suite exercises them without a window. What is here is the
--  bookkeeping and the drawing.
--
--  Which pane is which is written down at spawn, as pane ids, in
--  wezterm.GLOBAL under the window's id, with the set of panes that are
--  visible. Ids do not change when a pane is resized or when this file is
--  reloaded, and GLOBAL outlives a reload; the position and the size of a
--  pane do not identify it, because the layout is exactly what moves.
-- ----------------------------------------------------------------------------
local panes = dofile(wezterm.config_dir .. "/panes.lua")

--- Writes down the panes of a window and which of them are visible.
---
--- GLOBAL hands out copies, so the table is read, changed and put back whole.
local function remember(window_id, record)
  local all = wezterm.GLOBAL.workstation_panes or {}
  all[tostring(window_id)] = record
  wezterm.GLOBAL.workstation_panes = all
end

--- The width or the height of a pane, in cells.
local function measure(tab, pane_id, dimension)
  for _, info in ipairs(tab:panes_with_info()) do
    if info.pane:pane_id() == pane_id then return info[dimension] end
  end
  return nil
end

--- The size of the tab, in cells, from the panes that fill it.
local function tab_size(tab)
  local cols, rows = 0, 0
  for _, info in ipairs(tab:panes_with_info()) do
    cols = math.max(cols, info.left + info.width)
    rows = math.max(rows, info.top + info.height)
  end
  return cols, rows
end

--- Resizes a pane until its width or height is `want`.
---
--- AdjustPaneSize moves the divider of the active pane by a number of cells,
--- and which way a direction moves it depends on which side of the divider
--- the pane is on. Rather than rely on a guess about that, each step is
--- measured. A step that makes the error larger turns the directions round,
--- once, and the next step corrects it. A step that moves nothing is either
--- the edge of what the window allows, if an earlier step has already shown
--- the directions right, or a direction that does nothing from here, and it is
--- turned round once. Past that it stops.
local function fit(window, pane, dimension, want, bigger, smaller)
  pane:activate()
  local tab       = pane:tab()
  local pane_id   = pane:pane_id()
  local turned    = false
  local confirmed = false
  local have      = measure(tab, pane_id, dimension)

  for _ = 1, 6 do
    local error = want - have
    if error == 0 then return end

    window:perform_action(
      action.AdjustPaneSize({ error > 0 and bigger or smaller, math.abs(error) }), pane)

    local now = measure(tab, pane_id, dimension)
    if math.abs(want - now) < math.abs(error) then
      confirmed = true
    else
      if confirmed or turned then return end
      turned = true
      bigger, smaller = smaller, bigger
    end
    have = now
  end
end

--- Draws what panes.decide asked for.
---
--- Always from the unzoomed layout, so a state that has drifted -- a pane
--- resized by the mouse, a zoom undone by moving the focus -- is drawn again
--- from scratch rather than adjusted.
local function render(window, tab, roles, decision)
  tab:set_zoomed(false)

  local cols, rows = tab_size(tab)
  local want = panes.sizes(decision.mode, decision.pane, cols, rows,
                           layout.agent_pane_width, layout.terminal_pane_height)
  fit(window, mux.get_pane(roles.agent), "width",  want.agent_cols, "Left", "Right")
  fit(window, mux.get_pane(roles.shell), "height", want.shell_rows, "Up",   "Down")

  mux.get_pane(roles[decision.focus]):activate()
  if decision.mode == "zoom" then tab:set_zoomed(true) end
end

--- What a Ctrl+Shift+digit key does, for the role it is bound to.
---
--- In a window without the workstation layout there is no record, and the key
--- does nothing. The same when a pane of the layout has been closed: then
--- the three roles no longer exist and there is nothing to arrange. Closing a
--- pane is not undone by the keys, so they stay inert for that window.
local function toggle_pane(window, role)
  local all    = wezterm.GLOBAL.workstation_panes
  local record = all and all[tostring(window:window_id())]
  if record == nil then return end

  -- mux.get_pane raises for an id that no longer exists, rather than
  -- returning nil, so each lookup is protected. The tab is found through
  -- whichever of the three panes is left; when none is, there is no layout.
  local tab = nil
  for _, name in ipairs(panes.ROLES) do
    local found, pane = pcall(mux.get_pane, record[name])
    if found and pane ~= nil then
      tab = pane:tab()
      break
    end
  end
  if tab == nil then return end

  local live = {}
  for _, pane in ipairs(tab:panes()) do live[#live + 1] = pane:pane_id() end
  local roles = panes.resolve(record, live)
  if roles == nil then return end

  local focused = nil
  local active  = window:active_pane()
  if active ~= nil then
    for name, id in pairs(roles) do
      if id == active:pane_id() then focused = name end
    end
  end

  local decision = panes.decide(record.visible or {}, role, focused)
  if not decision.changed then return end

  render(window, tab, roles, decision)
  remember(window:window_id(), {
    agent = roles.agent, editor = roles.editor, shell = roles.shell,
    visible = decision.visible,
  })
end

local function toggle_key(role)
  return wezterm.action_callback(function(window)
    toggle_pane(window, role)
  end)
end


-- ----------------------------------------------------------------------------
--  5. Pane key bindings
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

  -- Show or hide the agent, the editor and the shell. By physical key, so
  -- they are the same keys on a layout where Shift+1 is not a 1.
  { key = "phys:1", mods = "CTRL|SHIFT", action = toggle_key("agent")  },
  { key = "phys:2", mods = "CTRL|SHIFT", action = toggle_key("editor") },
  { key = "phys:3", mods = "CTRL|SHIFT", action = toggle_key("shell")  },

  -- WezTerm's defaults map these same presses by character, and a mapped
  -- binding is matched before a physical one: Ctrl+Shift+1/2/3 and, because
  -- Shift+1/2/3 types ! @ # on a US layout, Ctrl(+Shift) with those, all go to
  -- ActivateTab. Without these lines the toggles never fire. Only these keys
  -- are released; Ctrl+Shift+4..9 and the rest of the defaults stay.
  { key = "1", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },
  { key = "2", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },
  { key = "3", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },
  { key = "!", mods = "CTRL",       action = action.DisableDefaultAssignment },
  { key = "!", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },
  { key = "@", mods = "CTRL",       action = action.DisableDefaultAssignment },
  { key = "@", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },
  { key = "#", mods = "CTRL",       action = action.DisableDefaultAssignment },
  { key = "#", mods = "CTRL|SHIFT", action = action.DisableDefaultAssignment },

  -- Close the current pane
  { key = "w", mods = "CTRL|SHIFT", action = action.CloseCurrentPane({ confirm = true }) },

  -- Resize from the keyboard as well as the mouse
  { key = "H", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Left",  3 }) },
  { key = "L", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Right", 3 }) },
  { key = "K", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Up",    3 }) },
  { key = "J", mods = "CTRL|SHIFT|ALT", action = action.AdjustPaneSize({ "Down",  3 }) },
}


-- ----------------------------------------------------------------------------
--  6. Command builders
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

--- Maximises the window, where doing so is not known to destroy it.
---
--- On Wayland, maximising kills the window often enough to have taken two
--- launches out of four in a measured run. The compositor configures a
--- maximised state, WezTerm commits a buffer that does not match it, and the
--- xdg_wm_base protocol error terminates the process:
---
---   xdg_surface buffer (1816 x 1116) does not match
---                the configured maximized state (1920 x 2112)
---
--- Three things were previously believed about this, and all three were wrong.
--- The surface is not "still at its default size" — that buffer is the full
--- window. Deferring past the first buffer commit does not avoid the race; the
--- deferral was in place for both failures. And pcall does not keep the failure
--- cosmetic: it catches Lua errors, and this is a protocol error that takes the
--- GUI process with it. The deferral and the pcall are kept because they cost
--- nothing, not because they work.
---
--- What changed is what maximising is worth. It used to be load-bearing: the
--- window opened at 80x24 and the panes were unusable until it grew. Now the
--- window is born large enough for every pane, so maximising buys the window
--- filling the screen and nothing else. That is not worth half the launches.
---
--- So it is skipped on Wayland. The evidence is from one compositor and other
--- Wayland sessions may well be fine, but the costs are not symmetric: being
--- wrong here means the window does not fill the screen, and being wrong the
--- other way means it dies.
local function maximize_when_ready(window)
  if not layout.maximize_on_start then return end

  local wayland = os.getenv("WAYLAND_DISPLAY")
  if wayland ~= nil and wayland ~= "" then
    wezterm.log_info(
      "workstation: not maximising on Wayland, where it terminates the window. " ..
      "The window opens at its configured size instead.")
    return
  end

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
--  7. The workstation layout
--
--  When this window is a workstation (see Identity above), this builds the
--  three-pane workspace over its project directory:
--
--      +------------------------------+-------------------+
--      |  Neovim                      |                   |
--      |  file tree + current file    |  AI agent         |
--      |                              |                   |
--      +------------------------------+                   |
--      |  Shell                       |                   |
--      +------------------------------+-------------------+
--
--  Otherwise WezTerm opens an ordinary window.
-- ----------------------------------------------------------------------------
wezterm.on("gui-startup", function(spawn_command)

  -- Case 1: ordinary start, no layout requested
  if workstation == nil then
    local _, _, window = mux.spawn_window(spawn_command or {})
    maximize_when_ready(window)
    return
  end

  -- Case 2: the workstation layout
  local agent             = workstation.agent
  local project_directory = workstation.directory

  -- Pane 1, left: Neovim over the project directory
  local _, editor_pane, window = mux.spawn_window({
    cwd  = project_directory,
    args = editor_command(),
  })

  maximize_when_ready(window)

  -- Pane 2, right: the AI agent
  local agent_pane = editor_pane:split({
    direction = "Right",
    size      = layout.agent_pane_width,
    cwd       = project_directory,
    args      = run_then_keep_shell(agent),
  })

  -- Pane 3, bottom left: a free shell to run the project
  local shell_pane = editor_pane:split({
    direction = "Bottom",
    size      = layout.terminal_pane_height,
    cwd       = project_directory,
  })

  -- Write down which pane is which, for the keys that show and hide them
  remember(window:window_id(), {
    agent   = agent_pane:pane_id(),
    editor  = editor_pane:pane_id(),
    shell   = shell_pane:pane_id(),
    visible = { agent = true, editor = true, shell = true },
  })

  -- Leave the focus on the editor
  editor_pane:activate()
end)


return config
