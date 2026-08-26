# Usage

---

## Opening the workspace

From inside a project directory:

```powershell
Start-Workstation                                   # Claude Code
Start-Workstation -Agent codex                      # Codex
Start-Workstation -Agent antigravity                # Antigravity CLI
Start-Workstation -Agent opencode                   # opencode

Start-Workstation -Agent claude -Directory D:\projects\shop
```

`ws` is the alias, for the command typed every day:

```powershell
ws
ws codex
ws opencode D:\projects\shop
```

The explicit name stays the real command — it is what `Get-Command` finds and
what this documentation uses. The alias exists so that sitting down to work
costs two letters, the same way `macss` carries `ma`.

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
    Terminal = @{ ColorScheme = 'Catppuccin Mocha'; FontFamily = 'Cascadia Code'; FontSize = 13.0 }
    Editor   = @{ ColorScheme = 'catppuccin'; TabWidth = 4; FileTreeWidth = 42 }
    Layout   = @{ AgentPaneWidth = 0.45; MaximizeOnStart = $false }
    Workstation = @{ DefaultAgent = 'opencode' }
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
