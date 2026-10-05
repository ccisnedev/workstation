# 9. The editor reloads what the agent edited

Date: 2026-10-05

## Status

Accepted

## Context

The editor and the agent share a window and a working tree, and they do not
share a view of it. When the agent edits a file Neovim already has open, the
buffer keeps showing the old text until something makes Neovim look at the
disk again, which is usually the person pressing a key in a window the agent
did not touch. The panel that shows what the agent changed
(`Space` `D`) reads the disk and is right; the buffer beside it is stale.

Neovim can be told. It listens on an address when started with `--listen`, and
`nvim --server <address> --remote-expr` evaluates an expression in that
running editor and prints the result. What is missing is something that knows
when the agent has edited a file, and an address both sides know.

Claude Code has the first. A **mod** is a small module loaded with
`--plugin-dir` that hooks the agent's own events, here `tool.call`, and runs
with only the powers it declares: it has no Node APIs, and `claude plugin
validate` lists every call it can make. Codex, Antigravity and opencode have no
such hook, so for them there is nothing to listen to.

Several windows can be open at once, each over its own project, and often two
over the same one. An address shared between them would make an agent reload
a file in someone else's editor.

[ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md) rules out
installing the mod into Claude's own configuration.

## Decision

After the agent edits a file, the mod tells the editor beside it which file,
and the editor reloads that buffer if doing so loses nothing.

1. **Each window gets its own server address.** `Start-Workstation` names one
   per launch: a named pipe, `\\.\pipe\workstation-nvim-<id>`, on Windows, and
   a socket named `nvim-<id>.sock` under the status directory elsewhere, which
   the workstation owns and the uninstaller removes. The id is random, so two
   windows over the same project differ. The address is set as
   `WORKSTATION_NVIM_SERVER` for the window, cleared from the launching shell
   afterwards, and `wezterm.lua` starts the editor pane as
   `nvim --listen <address> .`. The agent pane inherits the variable. With no
   address the editor starts as it always did.

2. **The mod is loaded for the launch, not installed.** `Start-Workstation`
   adds `--plugin-dir <repository>/code/assets/claude/reload-mod` to claude's
   command, beside `--settings`, with or without the settings. A claude opened
   outside the workstation does not have it. Other agents are started exactly
   as before.

3. **The mod hooks four tools and does one thing.** After `Edit`, `Write`,
   `MultiEdit` or `NotebookEdit` has run, and not before, it runs
   `nvim --headless --server <address> --remote-expr
   "v:lua.workstation_reload('<path>')"`. The path is the absolute one the tool
   was given, with single quotes doubled. The command is an argument list run
   by `$.process.run`; no shell reads it.

4. **The mod has the least authority that works.** It calls `$.env.get`, to
   read the one variable, and `$.process.run`. `claude plugin validate` lists
   those and nothing else, and the suite asserts that listing, so a later
   change that gives the mod another power fails visibly.

5. **The mod never changes what the agent sees.** A tool that was denied or
   failed triggers nothing. An unset variable triggers nothing. If the command
   cannot be run, is denied, or exits non-zero, because the editor is not open
   or has been closed, the tool's result is returned unchanged and nothing
   reaches the transcript. A reload that did not happen is a stale buffer,
   which is the state before this decision; it is not worth a failed edit.

6. **The editor reloads only what it can reload without loss.**
   `workstation_reload` is defined in `code/assets/neovim/reload.lua`, which
   `init.lua` loads. For a path with no loaded buffer it does nothing and
   opens nothing. For a loaded buffer with unsaved changes it leaves the text
   alone and shows a notice that names the file. For any other loaded buffer it
   runs `checktime` on it, so the buffer is reloaded whether or not it is
   visible. It does not move the cursor, change the window, or change the
   current buffer.

7. **It reloads and does not open.** Jumping to the file the agent edited
   would move the person's attention several times a minute. Whether to follow
   the agent is a different decision and is not taken here.

## Consequences

**The first mod.** The workstation has shipped a script for Claude to run
(ADR 0008) but never a module hooked into Claude's events. A mod is a second
place that knows Claude Code's shape: if the hook's types change, `claude
plugin test` is where it shows.

**Only claude reloads.** The other three agents have no hook, so for them the
buffer stays stale until Neovim looks again, as it does today.

**The mod needs `nvim` on the path.** It is the same `nvim` the editor pane
runs. Without it the command fails and, by point 5, nothing is said.

**`--headless` is part of the argument list.** On Windows `nvim --remote-expr`
without it starts the terminal interface of the client, writes control
sequences to a piped standard output and loses the result. The client is
headless and the server is the editor.

**The function sits in its own file.** The suite loads `reload.lua` into a
headless Neovim without the plugin set, which is what lets it run the exact
argument list the mod builds against a real server.

**A modified buffer is not reloaded.** The person keeps their edits, and the
notice says the disk has moved. Resolving it is the person's call.

**The reload suite needs Neovim, Node and claude.** It runs where they are
installed, and not in CI as it stands.

## References

- [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md), on
  why the mod is loaded per launch and Claude's configuration is not written
- [ADR 0008](0008-the-agent-pane-tells-the-status-bar-what-it-knows.md), the
  other thing the workstation has put in the agent pane
- `code/assets/claude/reload-mod`, the mod and its own tests
- `code/powershell/Workstation/Tests/Invoke-ReloadQA.ps1`, which asserts every
  point above
