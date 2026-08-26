# Installation

---

## Requirements

- **PowerShell 7 or later** on every platform, including Linux
- **Git**
- **WezTerm**, **Neovim**, **ripgrep**, **fd**
- At least one AI agent: Claude Code, Codex, Antigravity CLI or opencode

`Install-Workstation -Plan` reports which of these are missing. Read the plan:
anything it lists as pending is what the apply will do, tool installs included.
It performs nothing you have not seen first.

Administrator rights are **not** required on any platform.

---

## Windows

```powershell
git clone https://github.com/ccisnedev/workstation.git $HOME\develop\workstation
cd $HOME\develop\workstation
Import-Module .\code\powershell\Workstation

Install-Workstation -Plan
```

Read what it says it would do. Then:

```powershell
Install-Workstation -Apply
```

Missing tools are installed with winget as part of that run, because the plan
named them and you said yes. Nothing else reaches a package manager.

Open a new terminal afterwards, so the profile block loads and the tools just
installed are on `PATH`:

```powershell
ws
```

---

## Linux

> **Verified** on Ubuntu 22.04 (WSL2) by 131 assertions — see
> [testing.md](testing.md). Symbolic links, XDG paths, `fdfind` detection,
> `NVIM_APPNAME` resolution, preference resolution, three full
> uninstall/reinstall cycles, and opening the three-pane window for each of the
> four agents under Xvfb.
>
> macOS takes the same branch as Linux but has not been tested at all.

Install PowerShell 7 first, since the module is PowerShell:

```bash
# Ubuntu and Debian
sudo apt update && sudo apt install -y powershell
```

Then the tools, which are reported but never installed on Linux:

```bash
sudo apt install -y git neovim ripgrep fd-find
# WezTerm: see https://wezterm.org/install/linux.html
```

Then the same three commands, from `pwsh`:

```powershell
git clone https://github.com/ccisnedev/workstation.git ~/develop/workstation
cd ~/develop/workstation
Import-Module ./code/powershell/Workstation

Install-Workstation -Plan
Install-Workstation -Apply
```

Two differences from Windows, both handled automatically:

- the link is a symbolic link rather than a junction
- the Neovim configuration is deployed to `$XDG_CONFIG_HOME/workstation`,
  defaulting to `~/.config/workstation`

On Debian and Ubuntu `fd` is packaged as `fdfind`, which the declared state
already accounts for.

---

## Installing the AI agents

None of these is installed by the workstation, because every one of them
requires an interactive sign-in.

| Agent | Windows | Linux and macOS |
|---|---|---|
| Claude Code | `npm install --global @anthropic-ai/claude-code` | same |
| Codex | `npm install --global @openai/codex` | same |
| Antigravity CLI | `irm https://antigravity.google/cli/install.ps1 \| iex` | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` |
| opencode | `npm install --global opencode-ai` | same |

Run each one once after installing, to sign in.

---

## Verifying

```powershell
Test-Workstation
```

Read-only. It prints every element of the declared state and marks it:

| Mark | Meaning |
|---|---|
| `in sync` | Matches the declared state |
| `pending` | Differs; `Install-Workstation -Apply` would correct it |
| `missing` | Absent and not ours to install; the install command is shown |
| `blocked` | Something upstream prevents it |

---

## Moving the repository

The links point at wherever the repository was when the installer last ran. If
you move it, the links break until you run the installer again from the new
location:

```powershell
cd <new location>
Install-Workstation -Apply
```

It detects the stale link and repoints it, reporting the old target first.

---

## Uninstalling

Nothing was replaced, so nothing has to be restored.

```powershell
# 1. Remove the link. This removes the link only, never its contents.
[System.IO.Directory]::Delete("$env:LOCALAPPDATA\workstation", $false)   # Windows
# rm ~/.config/workstation                                              # Linux

# 2. Delete the marked block from the profile
notepad $PROFILE.CurrentUserAllHosts

# 3. Optionally drop the downloaded plugins
Remove-Item -Recurse "$env:LOCALAPPDATA\workstation-data"
```

Your own Neovim and WezTerm configurations were never touched, so there is
nothing to undo there.
