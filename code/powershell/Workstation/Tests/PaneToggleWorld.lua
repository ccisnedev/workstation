-- ============================================================================
--  A fake WezTerm, for Invoke-PaneToggleQA
--
--  wezterm.lua is loaded against a stub of the `wezterm` module and driven
--  with fakes: a window of 200 by 50 cells holding the three panes, a mux that
--  spawns and splits them, and a window that performs AdjustPaneSize on
--  whichever pane is active. Nothing here touches a real window.
--
--  The fake obeys one convention for which way AdjustPaneSize moves a
--  divider. `reversed` turns it round, because the real one could not be asked
--  and the rendering must not depend on the guess. `shell_max` caps how tall
--  the shell can get, for a window that will not give as much as was asked.
--
--  Use:  local world = dofile(this_file).new({ dir = <wezterm dir>, reversed = false })
-- ============================================================================

local M = {}

local COLS, ROWS = 200, 50

local function round(x) return math.floor(x + 0.5) end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

function M.new(opts)
  local W = { calls = {}, panes = {}, windows = {}, next_pane = 1, next_window = 7, handlers = {}, store = {} }
  local function log(text) W.calls[#W.calls + 1] = text end

  -- wezterm.GLOBAL hands out copies and keeps copies, so a nested table
  -- mutated in place is lost, as it is in the real one.
  local GLOBAL = setmetatable({}, {
    __index    = function(_, k) return copy(W.store[k]) end,
    __newindex = function(_, k, v) W.store[k] = copy(v) end,
  })
  W.GLOBAL = GLOBAL

  local function new_tab()
    local tab = { zoomed = false, agent_w = 0, shell_h = 0, roles = {}, active = nil }
    function tab:live()
      local out = {}
      for _, role in ipairs({ "editor", "agent", "shell" }) do
        local p = self.roles[role]
        if p and p._alive then out[#out + 1] = { role = role, pane = p } end
      end
      return out
    end
    function tab:panes()
      local out = {}
      for _, e in ipairs(self:live()) do out[#out + 1] = e.pane end
      return out
    end
    function tab:panes_with_info()
      local left_w = COLS - self.agent_w - 1
      local geometry = {
        agent  = { left = COLS - self.agent_w, top = 0, width = self.agent_w, height = ROWS },
        editor = { left = 0, top = 0, width = left_w, height = ROWS - self.shell_h - 1 },
        shell  = { left = 0, top = ROWS - self.shell_h, width = left_w, height = self.shell_h },
      }
      local out = {}
      for _, e in ipairs(self:live()) do
        local g = geometry[e.role]
        out[#out + 1] = {
          pane = e.pane, left = g.left, top = g.top, width = g.width, height = g.height,
          is_active = (self.active == e.pane._id),
          is_zoomed = self.zoomed and self.active == e.pane._id,
        }
      end
      return out
    end
    function tab:set_zoomed(zoomed)
      log("zoom " .. tostring(zoomed) .. " on " .. tostring(self.active and W.panes[self.active]._role))
      local before = self.zoomed
      self.zoomed = zoomed
      return before
    end
    return tab
  end

  local function new_pane(tab, role)
    local id = W.next_pane
    W.next_pane = id + 1
    local p = { _id = id, _alive = true, _role = role }
    function p:pane_id() return id end
    function p:tab() return tab end
    function p:activate()
      tab.active = id
      log("activate " .. role)
    end
    function p:split(split)
      if split.direction == "Right" then
        tab.agent_w = round(COLS * split.size)
        return new_pane(tab, "agent")
      end
      tab.shell_h = round(ROWS * split.size)
      return new_pane(tab, "shell")
    end
    tab.roles[role] = p
    W.panes[id] = p
    return p
  end

  local mux = {}
  function mux.spawn_window(args)
    local tab = new_tab()
    local id = W.next_window
    W.next_window = id + 1
    tab.window_id = id
    W.windows[id] = tab
    local pane = new_pane(tab, "editor")
    tab.active = pane._id
    local window = {
      window_id  = function() return id end,
      gui_window = function() return { maximize = function() end } end,
    }
    return tab, pane, window
  end
  function mux.get_pane(id)
    local p = W.panes[id]
    if p and p._alive then return p end
    -- The real one raises for an id that no longer exists; it does not
    -- return nil.
    error("pane id " .. tostring(id) .. " not found")
  end

  local function gui_window(id)
    local tab = W.windows[id]
    local w = {}
    function w:window_id() return id end
    function w:active_pane() return tab and W.panes[tab.active] or nil end
    function w:perform_action(act)
      if act.name ~= "AdjustPaneSize" then
        log("perform " .. tostring(act.name))
        return
      end
      local dir, n = act.arg[1], act.arg[2]
      local active = tab.active and W.panes[tab.active]._role
      local grow = ({ agent = "Left", shell = "Up" })[active]
      if opts.reversed and grow then grow = ({ Left = "Right", Up = "Down" })[grow] end
      local delta = (dir == grow) and n or -n
      if active == "agent" then tab.agent_w = math.max(1, math.min(COLS - 2, tab.agent_w + delta)) end
      if active == "shell" then tab.shell_h = math.max(1, math.min(opts.shell_max or (ROWS - 2), tab.shell_h + delta)) end
      log("adjust " .. tostring(active) .. " " .. dir .. " " .. n)
    end
    return w
  end
  W.gui_window = gui_window

  local action = setmetatable({}, {
    __index = function(_, name) return function(arg) return { name = name, arg = arg } end end,
  })
  local wez = {
    config_dir = opts.dir, target_triple = "x86_64-pc-windows-msvc",
    GLOBAL = GLOBAL, mux = mux, action = action,
    config_builder = function() return {} end,
    font_with_fallback = function(f) return f end,
    font = function(f) return f end,
    on = function(name, fn) W.handlers[name] = fn end,
    action_callback = function(fn) return { callback = fn } end,
    add_to_config_reload_watch_list = function() end,
    log_info = function() end, log_warn = function() end, log_error = function() end,
    time = { call_after = function() end },
  }
  package.preload["wezterm"] = function() return wez end

  --- Loads wezterm.lua, as WezTerm does at start and again at every reload.
  function W.load_config()
    W.handlers = {}
    package.loaded["wezterm"] = nil
    W.config = dofile(opts.dir .. "/wezterm.lua")
    return W.config
  end

  --- Runs the gui-startup handler, which spawns a window.
  function W.startup() W.handlers["gui-startup"]({}) end

  --- The action bound to Ctrl+Shift+<digit> by physical key, or nil.
  function W.key_action(n)
    for _, k in ipairs(W.config.keys) do
      if k.key == "phys:" .. n and k.mods == "CTRL|SHIFT" then return k.action end
    end
    return nil
  end

  --- Presses Ctrl+Shift+<digit> in a window, as WezTerm would call the action.
  function W.press(n, window_id)
    local w = gui_window(window_id or 7)
    W.key_action(n).callback(w, w:active_pane())
  end

  --- Puts the focus on a role, as a click would, and forgets the call log.
  function W.focus(role, window_id)
    W.windows[window_id or 7].roles[role]:activate()
    W.calls = {}
  end

  --- Closes a pane, as exiting its shell would.
  function W.close(role, window_id)
    W.windows[window_id or 7].roles[role]._alive = false
  end

  --- The roles the bookkeeping says are visible, for the window.
  function W.visible(window_id)
    local r = (GLOBAL.workstation_panes or {})[tostring(window_id or 7)]
    if r == nil then return "none" end
    local out = {}
    for _, role in ipairs({ "agent", "editor", "shell" }) do
      if r.visible[role] then out[#out + 1] = role end
    end
    return table.concat(out, ",")
  end

  --- What the fake window looks like.
  function W.shape(window_id)
    local tab = W.windows[window_id or 7]
    local active = tab.active and W.panes[tab.active]._role or "none"
    return string.format("zoomed=%s active=%s agent_w=%d shell_h=%d",
      tostring(tab.zoomed), active, tab.agent_w, tab.shell_h)
  end

  return W
end

return M
