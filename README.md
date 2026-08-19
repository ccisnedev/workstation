# workstation

A three-pane terminal workspace: **Neovim** on the left, an **AI agent** on the
right, a **shell** at the bottom. One command opens it over any project.

```
+------------------------------+-------------------+
|  Neovim                      |                   |
|  file tree + current file    |  AI agent         |
|                              |  claude / codex   |
|                              |  antigravity      |
+------------------------------+  opencode         |
|  Shell                       |                   |
+------------------------------+-------------------+
```

Panes are focused by clicking and resized by dragging the divider. WezTerm
supplies the multiplexer, natively on Windows and Linux, so no tmux and no WSL
are involved.

The whole configuration lives in this repository and is deployed from a
**declared state**. Nothing is installed that is not written down here, and
nothing is written outside the paths this repository authored.

---

## Status: laboratory

This repository is the laboratory for a future `macss workstation` command in
[`ccisnedev/macss`](https://github.com/ccisnedev/macss). It is used daily and
refined here; MACSS inherits a decision only when a human ports it.

Nothing here is a MACSS contract. See
[ADR 0004](docs/adr/0004-this-repository-is-a-laboratory.md).

---

## Quick start

```powershell
git clone https://github.com/ccisnedev/workstation.git
cd workstation
Import-Module ./code/powershell/Workstation

Install-Workstation -Plan     # see exactly what would change
Install-Workstation -Apply    # change it
```

Then open a new terminal and run:

```powershell
ws                    # Claude Code, over the current directory
ws codex              # Codex
ws antigravity        # Antigravity CLI
ws opencode           # opencode
```

`ws` is an alias. The real command is `Start-Workstation`, and everything the
documentation says uses the long name.

Full instructions, including Linux, are in [docs/installation.md](docs/installation.md).

---

## Commands

| Command | What it does |
|---|---|
| `Install-Workstation -Plan` | Print every step and write a plan file. Changes nothing |
| `Install-Workstation -Apply` | Perform the pending steps after one confirmation |
| `Test-Workstation` | Report drift from the declared state. Read-only |
| `Get-WorkstationPreference` | Show the resolved preferences and where they came from |
| `Start-Workstation` / `ws` | Open the workspace over a project |

`-Plan` and `-Apply` are mandatory and neither is a default: a bare
`Install-Workstation` is an error that asks you to choose. See
[ADR 0003](docs/adr/0003-plan-and-apply-are-mandatory-for-every-mutating-command.md).

---

## Making it yours

Colours, fonts, the leader key and the pane proportions are **preferences**, not
architecture. They ship as defaults and are overridden in a file of your own —
never by editing anything the repository owns:

```
Windows   %LOCALAPPDATA%\workstation.preferences.psd1
Linux     $XDG_CONFIG_HOME/workstation.preferences.psd1
```

Write only what you want to change:

```powershell
@{
    Terminal = @{ ColorScheme = 'Catppuccin Mocha'; FontSize = 13.0 }
    Editor   = @{ ColorScheme = 'catppuccin'; TabWidth = 4 }
    Layout   = @{ AgentPaneWidth = 0.45 }
}
```

Then `Install-Workstation -Apply`. Merging is section by section, so anything
left out keeps its default, and `git pull` never conflicts with your taste.

```powershell
Get-WorkstationPreference -ShowSources   # what resolved, and from where
```

See [ADR 0005](docs/adr/0005-architecture-and-preference-are-different-things.md).

---

## It never touches your own setup

The workstation deploys into paths it is the sole author of:

| Tool | How it is deployed | Your own config |
|---|---|---|
| Neovim | Under `NVIM_APPNAME=workstation`, in its own directory | Plain `nvim` is untouched |
| WezTerm | Passed with `wezterm --config-file` | Plain `wezterm` is untouched |
| PowerShell profile | A block between two markers | Everything outside the markers is preserved |

See [ADR 0002](docs/adr/0002-the-workstation-never-owns-what-it-did-not-create.md).

---

## Layout

```
workstation/
├── code/
│   ├── assets/                     # what gets deployed
│   │   ├── neovim/                 #   init.lua + pinned plugin versions
│   │   └── wezterm/                #   the three-pane layout
│   └── powershell/
│       └── Workstation/            # the engine
│           ├── DeclaredState.psd1  #   architecture: what must exist, and where
│           ├── Preferences.psd1    #   taste: shipped defaults, overridable
│           ├── Workstation.psm1
│           └── Tests/              #   261 assertions across five suites
└── docs/
    ├── adr/                        # decisions, ported to MACSS by reference
    ├── architecture.md
    ├── installation.md
    ├── testing.md
    └── usage.md
```

---

## Verified

| Suite | Platform | Assertions | Result |
|---|---|---|---|
| `Invoke-WindowsQA` | Windows 10, PowerShell 7.6.4 | 57 | all passed |
| `Invoke-PreferenceQA` | Windows 10 | 40 | all passed |
| `Invoke-LaunchQA` | Windows 10, all four agents | 33 | all passed |
| `Invoke-LinuxQA` | Ubuntu 22.04 (WSL2), Neovim 0.12.4 | 52 | all passed |
| `Invoke-PreferenceQA` | Ubuntu 22.04 | 40 | all passed |
| `Invoke-LinuxLaunchQA` | Ubuntu 22.04, Xvfb, all four agents | 39 | all passed |

**261 assertions, all green.** The suites install, break, repair and uninstall
the workstation on the machine that runs them. The five defects they have caught,
and what is deliberately not covered, are in [docs/testing.md](docs/testing.md).

---

## Documentation

- [Architecture](docs/architecture.md) — declared state, links, steps and preferences
- [Installation](docs/installation.md) — a new machine, on Windows or Linux
- [Usage](docs/usage.md) — daily commands, key bindings, and how to change things
- [Testing](docs/testing.md) — the suites, the results, and the gaps
- [Decisions](docs/adr/) — the five ADRs

---

## Requirements

PowerShell 7 or later, plus WezTerm, Neovim, Git, ripgrep and fd.
`Install-Workstation -Plan` reports which of those are missing and prints the
command to install each one. It never installs anything unless you pass
`-InstallMissingTools`.

At least one AI agent: Claude Code, Codex, Antigravity CLI or opencode. All four
require an interactive sign-in, so none of them is installed for you.
