# 9. Hiding a pane is drawn as a collapse or a zoom

Date: 2026-10-05

## Status

Accepted

## Context

Most of the time only the agent's chat is needed. The editor and the free shell
take two thirds of the window while they sit unused. The one way to clear them
was `Ctrl+Shift+Z`, which zooms the focused pane: it needs the focus moved to
the right pane first, and it shows one pane or all three, never two.

What was wanted is three keys, one per pane, each showing or hiding it. WezTerm
cannot do that directly. It has no operation that hides a pane and puts it back
where it was. `move_to_new_tab` takes a pane out of the layout and cannot bring
it back, and splitting a new pane in its place starts a new process, which would
kill the editor and the agent the person was in the middle of using. What it does
have is the size of a pane, which can be changed by a number of cells, and a
zoom, which shows one pane at the full size of the window.

## Decision

A hidden pane is drawn from those two things, and its process is never touched.

1. **Three visible is the layout.** The sizes the layout preferences give:
   `agent_pane_width` and `terminal_pane_height`.
2. **Two visible is a collapse.** The hidden pane is shrunk to one cell, a row
   for the editor and the shell, a column for the agent, and the other two share
   what it leaves.
3. **One visible is a zoom.** That pane is zoomed. No sliver shows.
4. **Each key flips its own pane.** A key that would leave nothing visible does
   nothing. After a key, the focus is on a visible pane: the one just shown, or,
   when the focused pane was the one hidden, the first one still visible.
5. **The decision is a pure function.** `code/assets/wezterm/panes.lua` takes
   the visible set, the pane whose key was pressed and the pane with the focus,
   and returns the new set, the mode, the pane the mode applies to and the focus.
   It calls no WezTerm API, so the pane toggle suite runs all seven visible sets
   by three keys through Neovim, as `identity.lua` is run. The sizes a mode asks
   for are computed there too. `wezterm.lua` does the drawing.
6. **Roles are pane ids, written down at spawn.** `gui-startup` records the
   ids of the agent, the editor and the shell, and the visible set, in
   `wezterm.GLOBAL` under the window's id. Nothing is found by where a pane is or
   how big it is, because the layout is exactly what the keys move. Ids survive a
   resize, and `GLOBAL` survives a reload of `wezterm.lua`, which WezTerm does to
   every live window when the file is saved. The state belongs to the window, so
   two workstations do not share it. A window without a record, or one whose
   three panes are no longer all there, is not the layout the keys were written
   for, and they do nothing in it.
7. **The drawing is measured.** AdjustPaneSize moves a divider by a number of
   cells, but which way a direction moves it depends on which side the active
   pane is on. Each step is measured, and a step that goes the wrong way turns the
   directions round once. The drawing always starts from the unzoomed window, so
   a pane the mouse resized is drawn again from scratch.
8. **The keys are bound by physical key.** `phys:1`, `phys:2` and `phys:3` with
   `Ctrl+Shift`, because on a Spanish layout `Shift+1` is `!` and a mapped `1`
   would never arrive. `Ctrl+Shift+Z` is untouched.

## Consequences

- **A one-cell sliver shows when two panes are visible.** WezTerm will not take
  a pane to zero. The sliver is the hidden pane's own divider and one row or one
  column of it.
- **The agent redraws when it comes back.** A pane shrunk to one column is a
  terminal one column wide for as long as it is collapsed. A full-screen agent
  interface lays itself out again when the size returns, and what it printed
  while it was narrow can be wrapped badly until it does.
- **A manual resize is reset on restore.** Restoring the layout puts the
  panes at the proportions of the preferences, not at wherever the mouse left
  them. Nothing remembers the earlier sizes, on purpose: that would be a second
  copy of the layout to keep in step with the first.
- **The recorded state can drift from the screen.** Moving the focus out of a
  zoomed pane with `Ctrl+Shift+Arrows` unzooms it, and `Ctrl+Shift+Z` toggles
  it, without the record knowing. The next key draws from the record again, so
  it puts the window back in step; a key that does nothing, because it would hide
  the last pane, does not.
- **The record is lost with the process.** `GLOBAL` lives as long as WezTerm
  does. A new launch starts with all three visible, which is out of scope here to
  change.
- **What a suite cannot show is the window moving.** The suite loads
  `wezterm.lua` against a fake WezTerm, with fake panes that obey one convention
  for the direction of a divider and a second run that obeys the opposite one. It
  proves the decision, the bookkeeping, the keys and that the drawing converges
  whichever way the real one goes. That the real windows move is a manual check,
  which the issue lists.

## References

- [ADR 0005](0005-architecture-and-preference-are-different-things.md), on why
  the proportions come from the preferences
- `code/assets/wezterm/panes.lua`, the decision
- `code/powershell/Workstation/Tests/Invoke-PaneToggleQA.ps1`, which asserts
  every point above that a suite can reach
