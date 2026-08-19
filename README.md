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
| `Start-Workstation` / `ws` | Open the workspace over a project |

`-Plan` and `-Apply` are mandatory and neither is a default: a bare
`Install-Workstation` is an error that asks you to choose. See
[ADR 0003](docs/adr/0003-plan-and-apply-are-mandatory-for-every-mutating-command.md).

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
│           ├── DeclaredState.psd1  #   the source of truth
│           └── Workstation.psm1
└── docs/
    ├── adr/                        # decisions, ported to MACSS by reference
    ├── architecture.md
    ├── installation.md
    └── usage.md
```

---

## Documentation

- [Architecture](docs/architecture.md) — how declared state, links and steps fit together
- [Installation](docs/installation.md) — a new machine, on Windows or Linux
- [Usage](docs/usage.md) — daily commands, key bindings, and how to change things
- [Decisions](docs/adr/) — the four ADRs

---

## Requirements

PowerShell 7 or later, plus WezTerm, Neovim, Git, ripgrep and fd.
`Install-Workstation -Plan` reports which of those are missing and prints the
command to install each one. It never installs anything unless you pass
`-InstallMissingTools`.

At least one AI agent: Claude Code, Codex, Antigravity CLI or opencode. All four
require an interactive sign-in, so none of them is installed for you.
