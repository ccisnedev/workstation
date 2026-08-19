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
