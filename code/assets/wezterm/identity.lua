-- ============================================================================
--  What tells one workstation apart from another
--
--  Lives in the repository at code/assets/wezterm/identity.lua, beside the
--  WezTerm configuration that loads it with dofile.
--
--  Four projects open at once are four identical windows unless something
--  names them. This module derives, from the project directory and the agent,
--  the two things a window shows so it can be told apart at a glance:
--
--    the title    "<project> · <agent>", for the taskbar and Alt+Tab
--    the accent   a colour, stable for a directory, drawn from a palette
--
--  It depends on nothing but Lua, on purpose: the preference suite runs it
--  through Neovim without opening a window, so the contract is tested where
--  the rendering cannot be.
-- ============================================================================

local M = {}

--- Twelve colours far enough apart to be told apart as a chip of text. A
--- directory hashes to one of them, so the accent is the same every time the
--- same project opens, on this machine or another.
M.PALETTE = {
  "#e5484d", -- red
  "#f76b15", -- orange
  "#ffc53d", -- amber
  "#bdee63", -- lime
  "#30a46c", -- green
  "#12a594", -- teal
  "#00a2c7", -- cyan
  "#0090ff", -- blue
  "#3e63dd", -- indigo
  "#6e56cf", -- violet
  "#ab4aba", -- plum
  "#e93d82", -- pink
}

M.LIGHT_TEXT = "#ffffff"
M.DARK_TEXT  = "#1c1c1c"
M.SEPARATOR  = " · "

--- Forward slashes, no trailing separator. Case is left alone: the name is
--- shown as the directory spells it, and only the hash lowercases it.
local function normalize(path)
  local text = tostring(path or ""):gsub("\\", "/")
  text = text:gsub("/+$", "")
  return text
end

--- The last component of the directory, which is what a person calls the
--- project.
function M.project_name(path)
  local text = normalize(path)
  return text:match("([^/]+)$") or text
end

function M.title(path, agent)
  return M.project_name(path) .. M.SEPARATOR .. tostring(agent)
end

--- djb2, kept within 32 bits so the arithmetic is exact in every Lua.
local function hash(text)
  local value = 5381
  for i = 1, #text do
    value = (value * 33 + text:byte(i)) % 4294967296
  end
  return value
end

function M.is_hex_color(value)
  return type(value) == "string" and value:match("^#%x%x%x%x%x%x$") ~= nil
end

--- The colour pinned to this project name in the preferences, if there is one
--- and it is a colour. Names match regardless of case; the value comes back
--- lowercased so the same colour reads the same wherever it is compared.
function M.pinned(name, pins)
  if type(pins) ~= "table" then return nil end
  local wanted = tostring(name):lower()
  for key, value in pairs(pins) do
    if tostring(key):lower() == wanted and M.is_hex_color(value) then
      return value:lower()
    end
  end
  return nil
end

--- A pin wins; otherwise the directory hashes to a palette colour. The hash
--- is over the lowercased, normalised path, so the case a shell happened to
--- spell the directory in and the separator it used do not change the colour.
function M.accent(path, pins)
  local pinned = M.pinned(M.project_name(path), pins)
  if pinned ~= nil then return pinned end
  local key = normalize(path):lower()
  return M.PALETTE[(hash(key) % #M.PALETTE) + 1]
end

--- One sRGB channel of a hex colour, linearised for the luminance formula.
local function channel(hex, position)
  local value = tonumber(hex:sub(position, position + 1), 16) / 255
  if value <= 0.03928 then return value / 12.92 end
  return ((value + 0.055) / 1.055) ^ 2.4
end

--- Light text on a dark accent, dark text on a light one, by relative
--- luminance. The threshold sits above the usual contrast midpoint because
--- the text is bold and the mid-tones of the palette read better in white.
function M.text_color(hex)
  local luminance = 0.2126 * channel(hex, 2) + 0.7152 * channel(hex, 4) + 0.0722 * channel(hex, 6)
  if luminance > 0.35 then return M.DARK_TEXT end
  return M.LIGHT_TEXT
end

--- Everything the window needs, in one table.
function M.describe(path, agent, pins)
  local accent = M.accent(path, pins)
  return {
    directory = path,
    agent     = tostring(agent),
    name      = M.project_name(path),
    title     = M.title(path, agent),
    accent    = accent,
    text      = M.text_color(accent),
  }
end

return M
