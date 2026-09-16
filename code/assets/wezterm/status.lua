-- ============================================================================
--  What the agent pane knows about itself, shown in the status bar
--
--  Lives in the repository at code/assets/wezterm/status.lua, beside the
--  WezTerm configuration that loads it with dofile.
--
--  An agent knows three things a person at the keyboard keeps asking: which
--  model is answering, how much of the context window is used, and how much
--  of the plan's limits it has spent. Claude Code hands those to a status
--  line command on every update; the workstation's command prints them for
--  Claude's own bar and writes them, as a Lua table, to the file named by
--  WORKSTATION_STATUS_FILE. This module reads that file and renders it.
--
--  It depends on nothing but Lua, on purpose: the status suite runs it
--  through Neovim without opening a window, so the contract is tested where
--  the rendering cannot be. WezTerm colours are applied by wezterm.lua from
--  the levels this module names.
-- ============================================================================

local M = {}

--- A reading older than this is shown as stale rather than as current: the
--- agent has exited, or is hung, and the last number it wrote is history.
M.STALE_AFTER_SECONDS = 600

--- The thresholds the usage report uses, so a percentage reads the same in
--- the terminal and in the status bar.
M.WARN_AT = 70
M.HIGH_AT = 90

--- Loads the status file. Anything that is not a Lua file returning a table
--- is nil: a missing file, a half-written one, or one from an older version
--- of the command.
function M.load(path)
  if path == nil or path == "" then return nil end
  local chunk = loadfile(path)
  if chunk == nil then return nil end
  local ok, loaded = pcall(chunk)
  if not ok or type(loaded) ~= "table" then return nil end
  return loaded
end

--- ok, warn or high, from a percentage; nil when there is no percentage.
function M.level(percent)
  if type(percent) ~= "number" then return nil end
  if percent >= M.HIGH_AT then return "high" end
  if percent >= M.WARN_AT then return "warn" end
  return "ok"
end

function M.is_stale(status, now)
  if type(status) ~= "table" or type(status.written_at) ~= "number" then return true end
  return (now - status.written_at) > M.STALE_AFTER_SECONDS
end

local function percent_text(value)
  return string.format("%d%%", math.floor(value + 0.5))
end

--- A token count as people say it: 500, 67k, 200k, 1M, 1.5M. Mirrors the
--- command, so Claude's own bar and this one read the same.
function M.tokens(count)
  if count >= 1000000 then
    local millions = string.format("%.1f", count / 1000000):gsub("%.0$", "")
    return millions .. "M"
  end
  if count >= 1000 then return string.format("%dk", math.floor(count / 1000 + 0.5)) end
  return string.format("%d", math.floor(count + 0.5))
end

--- "ctx 67k/200k 34%" when the window size is known, "ctx 34%" when not:
--- half of a small window and half of a large one are not the same
--- distance from a compact.
local function context_text(percent, window)
  if type(window) == "number" and window > 0 then
    return string.format("ctx %s/%s %s", M.tokens(window * percent / 100), M.tokens(window), percent_text(percent))
  end
  return "ctx " .. percent_text(percent)
end

--- The segments of the status line, in order, each with a text and a level.
--- An empty list means there is nothing to show: no file, no agent yet.
--- The model always comes first; the percentages follow only when known.
function M.segments(status, now)
  if type(status) ~= "table" then return {} end
  local segments = {}
  local stale = M.is_stale(status, now)

  if type(status.model) == "string" and status.model ~= "" then
    table.insert(segments, { text = status.model, level = stale and "stale" or "ok" })
  end

  local function add(text, percent)
    if type(percent) ~= "number" then return end
    local level = stale and "stale" or M.level(percent)
    table.insert(segments, { text = text, level = level })
  end

  if type(status.context_percent) == "number" then
    add(context_text(status.context_percent, status.context_window), status.context_percent)
  end
  if type(status.limits) == "table" then
    local limits = status.limits
    if type(limits.session_percent) == "number" then add("5h " .. percent_text(limits.session_percent), limits.session_percent) end
    if type(limits.week_percent) == "number" then add("wk " .. percent_text(limits.week_percent), limits.week_percent) end
  end

  return segments
end

--- The same, as one line of text, for a place without colour.
function M.text(status, now)
  local parts = {}
  for _, segment in ipairs(M.segments(status, now)) do
    table.insert(parts, segment.text)
  end
  return table.concat(parts, "  ")
end

return M
