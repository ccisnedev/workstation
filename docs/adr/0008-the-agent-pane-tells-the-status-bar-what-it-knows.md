# 8. The agent pane tells the status bar what it knows

Date: 2026-09-15

## Status

Accepted

## Context

[ADR 0007](0007-the-workstation-reads-the-limits-of-its-agents-and-computes-nothing.md)
left two facts out on purpose: which model is answering, and how much of the
context window the open session has used. Neither exists before a session is
open, so neither can be read by a command that runs first. They are facts an
agent knows about itself, and they change with every reply.

Claude Code publishes exactly those facts to a **status line command**: a
program named in its settings, run after every response with a JSON payload on
standard input that carries the model's display name, the session id, the
percentage of the context window used, the five-hour and weekly limits, and a
cost figure. Whatever the command prints is Claude's own bar. The settings that
name the command live in the user's `settings.json`, which the workstation does
not own and, by [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md),
does not write.

WezTerm, for its part, redraws a right-hand status every few seconds from a Lua
callback, which can read a file. Codex has no status hook at all: it publishes
its limits to its rollouts, which ADR 0007 already reads, and its model and
context to nothing.

Several workstation windows can be open at once, each over its own project,
so whatever a session writes has to be its own, not the machine's.

## Decision

The agent pane writes what it knows to a file the workstation names, and the
status bar reads that file. Nothing is asked of the agent; it is told where to
leave what it already reports.

1. **The status line command lives in the repository.**
   `code/assets/claude/statusline.ps1` is a PowerShell script that reads the
   payload, prints one line for Claude's own bar, and writes the same facts to
   a file. It is PowerShell because PowerShell is the one runtime every
   workstation already has, and it imports no module, so its cost is the
   shell's start.

2. **Claude is pointed at it through a generated settings file, never
   through its own.** `Install-Workstation -Apply` writes
   `claude-settings.json` under `workstation-generated`, a generated artifact
   like the resolved preferences, containing the `statusLine` entry and
   nothing else. `Start-Workstation` hands that file to `claude --settings`
   for the session it opens. The user's `settings.json` keeps whatever it
   has, and a claude opened outside the workstation is not affected.

3. **One status file per project, under the workstation's own directory.**
   The declared state names an `AgentStatus` directory under
   `workstation-generated/status`. `Start-Workstation` names a file in it from
   the project directory's name and a hash of its path, and sets
   `WORKSTATION_STATUS_FILE` for the window, so two windows over the same
   project share a reading and two projects with the same name do not.

4. **The file is a Lua table, written whole.** The status bar's reader is Lua,
   so the file is a Lua chunk returning a table, the same convention as the
   compiled preferences, with a header that says who wrote it. It is written
   beside its final name and moved into place, so the bar never reads half a
   file. The command writes only when the variable is set: fed to a claude
   opened by hand, it prints and writes nothing.

5. **The bar shows the model, the context, the two limits, and how old they
   are.** `code/assets/wezterm/status.lua` renders the file as segments: the
   model, then `ctx`, `5h` and `wk` percentages, each coloured by the same
   thresholds the usage report uses. The context segment also carries the
   tokens used over the window's size, `67k/200k`, because a percentage of
   a window is not a distance from a compact until the window is known. A
   reading older than ten minutes is shown dimmed rather than removed,
   because a stale number with its age is more honest than a bar that goes
   blank while the agent is thinking.

6. **Percentages only, again.** The payload carries a cost. The command never
   reads it, the file never contains it, and the status suite asserts both.
   [ADR 0007](0007-the-workstation-reads-the-limits-of-its-agents-and-computes-nothing.md),
   point 2, applies to every line the workstation shows.

7. **The status line never fails, and never fails in silence.** It exits
   zero whatever happens: Claude runs the command hundreds of times per
   session, and a command that broke the session would be worse than no
   status line at all. A payload it cannot read is not a failure and prints
   nothing, because Claude sends one before the first answer and on every
   interruption. Anything that does go wrong prints its reason on the line
   Claude shows in the agent's own bar, in one short line beside whatever
   was already known. The command runs unattended in a process nobody
   watches, so that bar is the only place a reason can be seen; a log file
   would be a log file nobody opens. What the command cannot report is its
   own absence, which is why the check looks for the file instead.

8. **Codex is not shown.** It has no status hook to feed the file, so a
   Codex pane has a bar with nothing on it rather than a bar with an old
   Claude reading on it. Its limits remain in `ws -Usage`.

9. **Uninstall removes the status directory.** It was created by the
   workstation, holds only readings, and is rebuilt by the next session.

## Consequences

**The workstation now writes during a session.** Until now every file it
produced was written by an install. The status file is written by the agent's
own process, several times a minute, into a directory the declared state names
and the uninstaller removes. Nothing is written anywhere else, and nothing is
written into the agents' own directories.

**The bar is only as current as the agent's last reply.** Claude runs the
command after each response, so a long generation shows the previous reading
until it ends, and a closed session leaves a last reading that dims after ten
minutes. The age is on the file, and the dimming is the signal.

**A claude opened without `--settings` has no bar.** `ws` always passes the
generated file, so the ordinary path is covered. Before the first
`Install-Workstation -Apply` the file does not exist; `ws` opens the agent
bare and warns once.

**The status suite needs Neovim.** The Lua reader is exercised through
`nvim --headless`, as the identity module is, so the suite runs where Neovim
is installed and not in CI as it stands.

**The command is a second place that knows the payload's shape.** If Claude
Code renames a field, the bar loses that segment and nothing else breaks; the
suite's fixture payload is where the shape is recorded.

## Amendment, 2026-09-17: point 5 is withdrawn

The tab bar shows none of this. Point 5 is withdrawn; points 1 to 4 and 6 to 9
stand as written.

In use, the bar and the agent's own line were the same four readings twice on
one screen, a hand's width apart: Claude prints them at the bottom of its pane,
where the person is already looking, and the tab bar repeated them at the top.
The copy further from the agent is the one to go. `wezterm.lua` no longer sets a
right status, no longer subscribes to `update-status`, and no longer reads
`WORKSTATION_STATUS_FILE`; the suite asserts each of those absences, so the
duplicate cannot come back by accident.

What is written is still written. The command still publishes the file, the
declared state still names the directory, the uninstaller still removes it, and
`status.lua` still ships and is still tested against its contract. The reason is
point 3: one file per project, named from the project's own directory. A window
that lists the workstations open on this machine -- which is where this is
going -- needs exactly that, and it would be the second time it was built if it
were deleted here for being momentarily unread.

## References

- [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md), on
  why the user's `settings.json` is not written
- [ADR 0005](0005-architecture-and-preference-are-different-things.md), on
  generated artifacts and the seams that let a suite point at fixtures
- [ADR 0007](0007-the-workstation-reads-the-limits-of-its-agents-and-computes-nothing.md),
  which this completes
- `code/powershell/Workstation/Tests/Invoke-StatusQA.ps1`, which asserts
  every point above
