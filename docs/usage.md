# Usage

---

## Opening the workspace

From inside a project directory, `ws` alone opens the default agent over the
current directory in a new session. Everything else is named; nothing is
positional, so `ws codex` and `ws 3` are errors rather than guesses:

```powershell
ws                                  # the default agent, here, a new session
ws -Project shop                    # a known project by name, a new session
ws -Project D:\projects\shop        # any directory, a new session
ws -List                            # the 20 most recent Claude sessions, numbered
ws -List -Limit 40
ws -Session 3                       # continue number 3 of the list just printed
ws -Session <session id>            # continue by id, no list needed
ws -Agent codex                     # another agent, for a new session
ws -Usage                           # how much of each agent's plan is used
ws -Usage -Agent codex              # one agent
```

`ws` is the alias of `Start-Workstation`, which is what `Get-Command` finds
and what this documentation uses. The alias exists so that sitting down to
work costs two letters, the same way `macss` carries `ma`.

### Projects

A project is a directory. `-Project` takes a path, or the name of a directory
Claude has been used in: the last component of the path, matched regardless
of case. Anything containing a separator, or starting with a drive, `.` or
`~`, is a path and must exist. A name that matches two directories is refused
and both are shown; give the path instead. A name Claude has never been used
in is unknown, and the error says so.

### Sessions

`ws -List` reads Claude Code's own history and prints the most recent
conversations across every project, newest first: a number, the project, when
it was last used, its title, and its directory with your home shortened to
`~`. The title is the one you gave the
conversation if you renamed it, else the short one Claude gave it, else the
first thing you said in it; the list cuts it at fifty characters.
Conversations Claude has already discarded are left out; one whose directory
no longer exists is shown and marked, and refuses to open.

The numbers belong to the terminal that printed them, until its next list. A
list printed in another terminal is not the one this terminal was shown, so
`ws -Session 3` in a terminal that has printed no list is refused and told to
list first. A session id works anywhere.

`ws -Session` opens the three panes over the session's own project and hands
Claude the conversation to resume. It is Claude by definition: `-Agent` with
another name is refused beside it, and `-Project` is refused beside it because
the session already knows its project. Both the transcript and the directory
are checked again at launch, whatever the list said.

Nothing about this is stored by the workstation: the list is Claude's history
file, read and never written.

### Limits

`ws -Usage` prints, for each agent that publishes its limits, whose plan it
is, how fresh the reading is, and one line per limit with the percentage used
and the local time it resets:

```
  claude       dev@example.com (max)                 read just now
    Session (5h)    6%  resets Tue 15/09 18:00
    Week           53%  resets Sun 20/09 20:00
  codex        dev@example.com (pro)                 read 2 h ago
    Week          100%  resets Sat 19/09 03:11
```

Percentages are the whole story. The plans are flat, so there is no price to
show and none is computed; see
[ADR 0007](adr/0007-the-workstation-reads-the-limits-of-its-agents-and-computes-nothing.md).

Claude is read live, from the same endpoint its own `/usage` screen uses,
with the token Claude keeps in its own credentials file. Codex publishes
nothing on request, so its row is the last limit its CLI recorded in a
session on this machine, and the line says how long ago that was. A pool
Codex names, such as its Spark pool, is a limit prefixed with the pool's name
when a recent session used it.

An agent that cannot be read at the moment is a line that says why rather
than an error: not signed in, sign-in expired (open the agent once and it
refreshes itself), the endpoint unreachable, or no Codex session recorded
yet. `-Agent` narrows the report to one agent; an agent that does not publish
its limits, such as `opencode`, says so when named. Nothing is written, and
the token never appears on the page.

`Get-WorkstationUsage` returns the same information as rows, for a script or
a status line: `Agent`, `Account`, `Plan`, `Source` (`live`, `rollout`,
`unavailable` or `unsupported`), `ReadAt`, `Reason`, and `Limits`, each with
`Name`, `Percent` and `ResetsAt`. `ws -Usage -PassThru` prints and returns
them.

---

## The panes

```
+------------------------------+-------------------+
|  Neovim                      |                   |
|  file tree + current file    |  AI agent         |
|                              |  38% of the width |
+------------------------------+                   |
|  Shell, 22% of the column    |                   |
+------------------------------+-------------------+
```

Both proportions are named constants at the top of
`code/assets/wezterm/wezterm.lua`. Change the two numbers to re-proportion the
workspace.

Quitting Neovim or the agent leaves a usable prompt rather than closing the
pane, so you can restart either one in place.

### The status bar

The right of the tab bar shows what the agent pane knows about itself:

```
Fable 5.1  ctx 67k/200k 34%  5h 8%  wk 54%
```

The model answering; the context window used, as tokens over the window's
size and as a percentage, because half of a small window and half of a large
one are not the same distance from a compact; and the five-hour and weekly
limits, as percentages. A segment turns amber at 70 % and red at 90 %, the
same thresholds `ws -Usage` uses. The bar dims when the reading is more than
ten minutes old: the agent has exited, or is still working on a long reply.
A segment the agent has not reported yet is left out, so a new session shows
the model alone until the first reply.

This works for Claude, which runs a status line command after every reply.
The command is `code/assets/claude/statusline.ps1` in this repository; it
prints the same line for Claude's own bar and writes the facts to a file
under `workstation-generated/status`, one per project, which WezTerm reads.
Claude is pointed at the command through a settings file
`Install-Workstation -Apply` generates and `ws` passes with `--settings`, so
your own Claude settings are never written and a claude opened outside the
workstation is unchanged. Before the first apply, `ws` opens Claude bare and
warns once.

Codex has no status hook, so a Codex pane shows nothing on the bar; its
limits are in `ws -Usage`. No price appears anywhere; see
[ADR 0008](adr/0008-the-agent-pane-tells-the-status-bar-what-it-knows.md).

### WezTerm key bindings

Control and Shift, chosen so nothing collides with Neovim or the agents.

| Binding | Action |
|---|---|
| Mouse click | Focus a pane |
| Drag the divider | Resize |
| `Ctrl+Shift+Arrows` | Move between panes |
| `Ctrl+Shift+D` | Split vertically |
| `Ctrl+Shift+E` | Split horizontally |
| `Ctrl+Shift+Z` | Zoom a pane to the full window, and back |
| `Ctrl+Shift+W` | Close the pane |
| `Ctrl+Shift+Alt+H/J/K/L` | Resize from the keyboard |
| `Ctrl` + click | Open a link |

### Neovim key bindings

The leader key is the **space bar**.

| Binding | Action |
|---|---|
| `Space` `E` | Toggle the file explorer |
| `Space` `F` | Find a file by name |
| `Space` `G` | Search for text across the project |
| `Space` `B` | List the open buffers |
| `Space` `D` | Review every change against git, side by side |
| `Space` `Shift` `D` | Close the review |
| `Space` `H` | The history of the file you are in |
| `]` `C` | Go to the next change in this file |
| `[` `C` | Go to the previous change in this file |
| `Space` `P` | Show the change under the cursor |
| `Space` `U` | Undo the change under the cursor |
| `Space` `L` | Who last changed this line |
| `Ctrl` `S` | Save |
| `Esc` | Clear the search highlight |

This Neovim runs under the application name `workstation`. Your own `nvim`
elsewhere on the machine is a different configuration and is unaffected.

An editor pane keeps the configuration it started with. WezTerm rereads its
own file when it changes, but Neovim does not: after an update, a pane that
was already open still has the old keys, and a key that is not bound falls
back to whatever Vim does with it — `Y` becomes *yank to the end of the line*,
which looks enough like a copy to read as a broken one. Close the pane and
open it again, or open the project in a new window.

### Reviewing what the agent changed

The gutter marks every added, changed and removed line as you type, so a file
you are reading already says which parts are new. `Space` `P` shows the
change under the cursor in full, `Space` `U` throws it away, and `]` `C` and
`[` `C` walk them.

`Space` `D` is the other view, the one to reach for after the agent says it
touched six files: a list of the changed files down one side and each one old
against new, side by side, as a source control panel does it. Move through the
list with `J` and `K` and open a file with `Enter`; `Space` `Shift` `D` closes
the whole thing. `Space` `H` is the same panel over the history of one file
instead of over the working tree.

### File explorer key bindings

Pressed inside the tree, not in the editor. The tree lists all of its own keys
with `?`, which is worth pressing once; these are the ones used most.

| Binding | Action |
|---|---|
| `Enter` | Open the file |
| `s` | Open it in a vertical split |
| `S` | Open it in a horizontal split |
| `a` | New file — end the name with `/` to make a folder instead |
| `A` | New folder |
| `r` | Rename |
| `d` | Delete |
| `y` `x` `p` | Copy, cut and paste inside the tree |
| `Y` | Copy the **path** to the system clipboard, to paste into the agent |
| `gy` | Copy the **file itself**, to paste into Explorer or another program |
| `gx` | Open it with the program the desktop gives it — a PDF in the reader |
| `gr` | Open the folder that contains it in the file manager |
| `i` | What the file is: size, permissions, dates |
| `H` | Show the hidden files as well |
| `/` | Filter the tree by name |
| `.` | Make the folder under the cursor the root |
| `Backspace` | Go up one folder |

`Y` and `gy` are the two halves of what dragging a file does elsewhere: `Y`
gives the agent pane a path to paste with `Ctrl+Shift+V`, `gy` gives the rest
of the desktop the file. Dragging a file from Explorer onto a pane also works
and pastes its path.

`gy` is Windows only: no other desktop has a single way to put a file on the
clipboard. Elsewhere it copies the path and says so.

---

## Changing how it looks

Colours, fonts, the leader key and the pane proportions are **preferences**.
They ship as defaults and are overridden in a file of your own. Never edit
`Preferences.psd1` for your own machine: it is shipped, so the next `git pull`
would conflict with your taste.

Write only the keys you want to change to:

```
Windows   %LOCALAPPDATA%\workstation.preferences.psd1
Linux     $XDG_CONFIG_HOME/workstation.preferences.psd1
```

```powershell
@{
    Terminal      = @{ ColorScheme = 'Catppuccin Mocha'; FontFamily = 'Cascadia Code'; FontSize = 13.0; WindowDecorations = 'TITLE | RESIZE' }
    Editor        = @{ ColorScheme = 'catppuccin'; TabWidth = 4; FileTreeWidth = 42 }
    Layout        = @{ AgentPaneWidth = 0.45; MaximizeOnStart = $false }
    Workstation   = @{ DefaultAgent = 'opencode' }
    ProjectColors = @{ shop = '#ff8800'; 'billing-api' = '#0090ff' }
}
```

Then apply:

```powershell
Install-Workstation -Plan     # shows: refresh the compiled preferences
Install-Workstation -Apply
```

To see what resolved and where each value came from:

```powershell
Get-WorkstationPreference -ShowSources
(Get-WorkstationPreference).Terminal.ColorScheme
```

Two colour schemes ship installed — `tokyonight` and `catppuccin` — so either
can be named without reinstalling anything. Naming one that no installed plugin
provides is reported at startup rather than silently ignored.

Everything you can set is listed with its default in
`code/powershell/Workstation/Preferences.psd1`, and that list is enforced: a key
or a section it does not declare is reported by name and ignored, rather than
being carried into the compiled file where nothing would read it. A typo in an
override used to be invisible — the preference you meant kept its default, so
the only symptom was that nothing happened. What is **not** there is
deliberate: the three-pane shape, what runs in each pane, and where the
configuration is deployed are architecture, and live in `DeclaredState.psd1`.

The one exception is `ProjectColors`, whose keys are project names and so
cannot be listed in advance. Anything written there is taken as is.

---

## Telling workstations apart

Four projects open at once are four identical windows unless something names
them. Every workstation window therefore carries two marks:

- **A title**: the project name, which is the last component of the directory
  it was opened over — `shop` for `D:\projects\shop`. The operating system
  prints it in the taskbar thumbnails and in Alt+Tab. Without it the title was
  whatever the focused pane last set, which changed with every click and read
  the same in every window.
- **A colour**, chosen from the project directory and stable across launches
  and machines, worn as a chip in the tab bar and on the pane dividers.

The colours are the resistor colour code, in its order: black, brown, red,
orange, yellow, green, blue, violet, grey, white. Hashing the directory picks
one of the ten, so two projects can land on the same one. When they do, pin a
colour by project name in the override file — the name is matched regardless
of case — and apply:

```powershell
@{ ProjectColors = @{ shop = '#ff8800'; 'billing-api' = '#0090ff' } }
```

A pin that is not a six-digit hex colour is ignored and the derived colour is
used. The palette and the derivation are architecture; which colour a project
gets is taste, which is why the pin is a preference.

---

## Changing something

The flow is always the same, and it is what makes this code rather than a pile
of settings:

```powershell
# 1. Edit the file. Wherever you open it from, it is the same file.
ws                      # then edit code/assets/neovim/init.lua

# 2. Commit
cd $HOME\develop\workstation
git add -A
git commit -m "Neovim: add the comment toggle plugin"
git push

# 3. On the other machine
git pull
```

If the change was only to a file that is already linked, there is nothing else
to do: the `git pull` already put it in place, because its place and the
repository are the same directory.

Re-run the installer only when you changed `DeclaredState.psd1` — a new tool, a
new link:

```powershell
Install-Workstation -Plan
Install-Workstation -Apply
```

### Adding a tool

One entry in `DeclaredState.psd1`:

```powershell
@{
    Name           = 'lazygit'
    Purpose        = 'Git interface in the bottom pane'
    Command        = 'lazygit'
    WindowsInstall = 'winget install --id JesseDuffield.lazygit --exact'
    LinuxInstall   = 'sudo apt install lazygit'
}
```

The `--id` in the Windows string is what makes the tool installable by an
apply. Advice written any other way is reported for you to run instead, which
is the right answer for a tool winget does not carry. Add `Required = $true`
only for a tool the workspace cannot open without: it withholds the closing
invitation until the tool is there, and nothing else.

### Adding a configuration directory

Create it under `code/assets/`, then declare the link:

```powershell
@{
    Name          = 'lazygit configuration'
    Source        = 'assets/lazygit'
    WindowsTarget = '{LOCALAPPDATA}/lazygit'
    LinuxTarget   = '{XDG_CONFIG_HOME}/lazygit'
}
```

Before adding a link, check it against
[ADR 0002](adr/0002-the-workstation-never-owns-what-it-did-not-create.md): the
target must be a path this repository is the sole author of. If the tool has no
way to namespace its configuration, do not link it — pass the file at launch
instead, the way WezTerm is handled.

### Changing the plugin set

Edit the `require("lazy").setup` block in `code/assets/neovim/init.lua`, restart
the workstation, then commit the updated `lazy-lock.json` along with it. The
lock file is what makes the other machine resolve the same versions.

---

## Removing it

```powershell
Uninstall-Workstation -Plan      # what would go
Uninstall-Workstation -Apply     # remove it
```

The same rule as the installer: `-Plan` and `-Apply` are mandatory and neither
is a default.

It removes the link it made, the preferences it compiled, the Claude settings
it generated, the status files the agents wrote, and the block it wrote into
your profile. Everything outside the markers in that profile is
kept, and a real directory found where the link belongs is reported and left
alone — if it is not our link, it is not ours.

It does **not** uninstall WezTerm, Neovim or the agents. They were not ours
before the install and are not ours after it. Neovim's plugin data and anything
an earlier apply moved aside are printed under *Left alone* so that
"uninstalled" does not quietly mean "except for these".

The repository is never touched, so `Install-Workstation -Apply` puts it all
back.

---

## Checking a machine

```powershell
Test-Workstation
```

Changes nothing. Use it after a `git pull`, after moving the repository, or when
something behaves unexpectedly.

For the full detail of what would be corrected:

```powershell
Install-Workstation -Plan
```

That writes a plan file under `.workstation/plans/`, which is useful to read or
to attach to an issue. Plan files are machine output and are not committed.

---

## Unattended runs

```powershell
Install-Workstation -Apply -AutoApprove
```

Skips the single confirmation. Everything else is identical, including the
printed step list.

It skips the question, not the plan, so on Windows an unattended run installs
any missing tool the plan names. A caller that does not want that declares a
state without them through `WORKSTATION_DECLARED_STATE`, which is what the QA
suites do. See
[ADR 0006](adr/0006-installing-a-declared-tool-is-an-ordinary-step.md).
