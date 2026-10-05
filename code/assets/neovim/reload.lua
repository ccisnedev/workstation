-- ============================================================================
--  Reload the file an agent has just edited
--
--  Lives in the repository at code/assets/neovim/reload.lua and is loaded by
--  init.lua. The mod in code/assets/claude/reload-mod calls the function below
--  through `nvim --server <address> --remote-expr`, after Claude has written a
--  file. See docs/adr/0009-the-editor-reloads-what-the-agent-edited.md
--
--  It reloads and nothing else. A path no buffer has loaded is ignored, so a
--  file the agent edits is never opened here. A buffer with unsaved changes is
--  never reloaded, so the person's text is never discarded. And it does not
--  move the cursor, change the window or change the current buffer, because
--  the person is typing in this editor while the agent works beside it.
-- ============================================================================

local is_windows = vim.fn.has("win32") == 1

--- A path in the one spelling two names of the same file share.
local function normalise(path)
  local normalised = vim.fs.normalize(path)
  if is_windows then normalised = normalised:lower() end
  return normalised
end

--- The loaded buffer holding `path`, or nil.
local function loaded_buffer(path)
  local wanted = normalise(path)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" and normalise(name) == wanted then return buffer end
    end
  end
  return nil
end

--- Called by the mod. Returns what it did, as text, so the caller can read it.
function _G.workstation_reload(path)
  local buffer = loaded_buffer(path)
  if buffer == nil then return "ignored" end

  if vim.bo[buffer].modified then
    vim.notify(
      vim.fn.fnamemodify(path, ":t") .. " changed on disk, and this buffer has unsaved changes, so it was not reloaded.",
      vim.log.levels.WARN)
    return "kept"
  end

  -- `checktime` on a named buffer compares it with the file and, with
  -- autoread, reloads it where it stands; no window or buffer is entered.
  vim.bo[buffer].autoread = true
  vim.cmd("silent checktime " .. buffer)
  return "reloaded"
end
