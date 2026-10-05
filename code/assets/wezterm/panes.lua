-- ============================================================================
--  Which panes of the workstation are shown
--
--  Lives in the repository at code/assets/wezterm/panes.lua, beside the
--  WezTerm configuration that loads it with dofile.
--
--  WezTerm cannot hide a pane and put it back where it was, so a hidden pane
--  is drawn from what WezTerm does have: three visible is the layout, two is
--  the hidden pane shrunk to its minimum, one is that pane zoomed. This module
--  is the decision, and only the decision: given what is visible and the pane
--  whose key was pressed, what should the window look like, and where should
--  the focus go. The drawing is in wezterm.lua.
--  See docs/adr/0009-hiding-a-pane-is-drawn-as-a-collapse-or-a-zoom.md
--
--  It depends on nothing but Lua, on purpose: the pane toggle suite runs it
--  through Neovim without opening a window, so the contract is tested where
--  the rendering cannot be.
-- ============================================================================

local M = {}

--- The three roles, in the order the focus falls back through them.
M.ROLES = { "agent", "editor", "shell" }

local function is_role(name)
  for _, role in ipairs(M.ROLES) do
    if role == name then return true end
  end
  return false
end

local function count(visible)
  local n = 0
  for _, role in ipairs(M.ROLES) do
    if visible[role] then n = n + 1 end
  end
  return n
end

local function first_visible(visible)
  for _, role in ipairs(M.ROLES) do
    if visible[role] then return role end
  end
  return nil
end

--- What the window should look like for a visible set.
---
--- Returns the mode, "layout", "collapse" or "zoom", and the pane it applies
--- to: the hidden one for a collapse, the shown one for a zoom, nil for the
--- layout.
local function mode_of(visible)
  local n = count(visible)
  if n == 3 then return "layout", nil end
  if n == 2 then
    for _, role in ipairs(M.ROLES) do
      if not visible[role] then return "collapse", role end
    end
  end
  return "zoom", first_visible(visible)
end

--- Decides the window after `pressed` is pressed.
---
--- `visible` is a set, { agent = true, editor = true, shell = true } with the
--- hidden ones absent. `focused` is the pane that has the focus, or nil when
--- it is not known. Returns a table:
---
---   visible   the new set
---   mode      "layout", "collapse" or "zoom"
---   pane      the pane the mode applies to, nil for the layout
---   focus     the pane to leave the focus on, always a visible one
---   changed   false when the key would have left nothing visible
---
--- A key flips its own pane. One that would hide the last visible pane does
--- nothing, and the window is described as it already is.
function M.decide(visible, pressed, focused)
  local current = {}
  for _, role in ipairs(M.ROLES) do current[role] = visible[role] and true or nil end

  if not is_role(pressed) then
    local mode, pane = mode_of(current)
    return { visible = current, mode = mode, pane = pane,
             focus = current[focused] and focused or first_visible(current), changed = false }
  end

  local after = {}
  for role, value in pairs(current) do after[role] = value end
  after[pressed] = (not current[pressed]) or nil

  if count(after) == 0 then
    local mode, pane = mode_of(current)
    return { visible = current, mode = mode, pane = pane,
             focus = current[focused] and focused or first_visible(current), changed = false }
  end

  -- The pane just shown takes the focus. Otherwise the focus stays where it
  -- is, unless that was the pane just hidden, and then it moves to the first
  -- pane still visible.
  local focus
  if after[pressed] then
    focus = pressed
  elseif focused ~= nil and after[focused] then
    focus = focused
  else
    focus = first_visible(after)
  end

  local mode, pane = mode_of(after)
  return { visible = after, mode = mode, pane = pane, focus = focus, changed = true }
end

return M
