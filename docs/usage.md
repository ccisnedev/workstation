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
it was last used, and its title. The title is the one you gave the
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
| `Ctrl` `S` | Save |
| `Esc` | Clear the search highlight |

This Neovim runs under the application name `workstation`. Your own `nvim`
elsewhere on the machine is a different configuration and is unaffected.

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

It removes the link it made, the preferences it compiled, and the block it
wrote into your profile. Everything outside the markers in that profile is
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
