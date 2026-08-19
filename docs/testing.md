# Testing

Three suites live in `code/powershell/Workstation/Tests/`. They derive their
paths from `$PSScriptRoot`, so they run from any clone, on any machine.

They are not unit tests. They install, break, repair and uninstall the
workstation on the machine that runs them, and assert against the real
filesystem — which is the only way to test a thing whose whole job is to change
a machine.

---

## Running them

```powershell
# Windows, no graphical session needed
pwsh -File ./code/powershell/Workstation/Tests/Invoke-WindowsQA.ps1

# Windows, opens a real window once per agent
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LaunchQA.ps1

# Linux and macOS
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LinuxQA.ps1
```

Each exits with the number of failed assertions, so `$LASTEXITCODE` is usable as
a gate.

Every suite creates its own fixtures — a decoy user Neovim configuration, a
decoy WezTerm configuration, a user line in the PowerShell profile — and removes
them at the end. Each leaves the workstation installed.

---

## What they assert

### `Invoke-WindowsQA.ps1` — 57 assertions

| Group | Covers |
|---|---|
| Command contract | A bare `Install-Workstation` fails; `-Plan -Apply` together fails; `Test-Workstation` takes neither; an undeclared agent is rejected by the binder; a non-existent directory raises exactly one error |
| Clean baseline | Uninstall removes link and block; check reports both as pending |
| Plan writes nothing | After `-Plan`, no link and no profile block exist; one plan file is written naming the pending work |
| Apply and idempotency | The link is a junction pointing at the assets; the config is readable through it; a second apply changes nothing; a plan afterwards reports zero pending |
| Round trip | Editing through the link appears in `git status`; `git checkout` reverts the file as seen through the link |
| Never owning | A pre-existing user Neovim config survives byte-for-byte; the user WezTerm directory is never linked; user lines in the profile survive; the marked block appears exactly once |
| Drift and repair | A deleted link is detected and repaired; a link pointing elsewhere is detected, named, repointed, and the decoy survives; a real directory is backed up rather than deleted; a corrupted profile block is restored without losing user content |
| Declining | Answering no to the confirmation writes nothing |
| Uninstall and reinstall | Three full cycles, each returning to fully in sync |

### `Invoke-LaunchQA.ps1` — 33 assertions

Opens the workspace once for each of **claude, codex, antigravity and
opencode**, and for each one asserts that WezTerm launched with this
repository's configuration file, that the editor pane runs Neovim under
`NVIM_APPNAME=workstation`, that the agent pane runs the right command, that the
bottom pane is a plain shell, that the agent process is alive, and that the
window closes cleanly.

Then it asserts that the plugin data landed in the workstation's own directory
rather than the user's, and that `WORKSTATION_AGENT` and
`WORKSTATION_DIRECTORY` were cleared from the calling session.

### `Invoke-LinuxQA.ps1` — 56 assertions

Everything the Windows suite covers, plus what only Linux can answer:

| Group | Covers |
|---|---|
| Platform resolution | The profile path is the Linux one; the link target resolves under `XDG_CONFIG_HOME`; the checked-out Lua has no carriage returns, proving the `.gitattributes` normalisation |
| Tool detection | `fd` is found under its Debian name `fdfind`; a missing WezTerm is reported with the Linux hint and not the winget one; the Antigravity hint is the shell installer, not the PowerShell one |
| Symbolic links | The link is a `SymbolicLink`, not a junction |
| Neovim namespace | `NVIM_APPNAME=workstation` resolves to the deployed directory, plain `nvim` resolves elsewhere, the plugin data directories differ, and the deployed `init.lua` loads without a Lua error |
| Clean failure | Launching without an installed agent raises exactly one error, naming the Linux install command, with no `CommandNotFoundException` underneath |

---

## Results

| Suite | Platform | Assertions | Result |
|---|---|---|---|
| `Invoke-WindowsQA` | Windows 10 19045, PowerShell 7.6.4 | 57 | all passed |
| `Invoke-LaunchQA` | Windows 10 19045 | 33 | all passed |
| `Invoke-LinuxQA` | Ubuntu 22.04.5 (WSL2), PowerShell 7.6.5, Neovim 0.12.4 | 56 | all passed |

**146 assertions, all green**, as of 2026-08-19.

---

## What is not covered

**Opening the window on Linux.** `Invoke-LaunchQA.ps1` is Windows-only, because
the Linux environment available for testing was WSL2 on Windows 10, which has no
graphical session. `Install-Workstation` and `Test-Workstation` are proven on
Linux; `Start-Workstation` is not. Until someone runs it on a Linux desktop with
WezTerm installed, treat the three-pane layout there as unverified.

**macOS.** Not tested at all. The code takes the same branch as Linux, so it is
plausible rather than proven.

**The Neovim configuration itself.** The suites assert that `init.lua` is read
without a Lua error and that plugins clone into the right directory. They do not
assert that any key binding works. That is left to daily use, which is what this
laboratory is for.

---

## What the suites have already caught

Two defects, both found by assertions rather than by using the tool:

1. **`@()` assigned from inside an `if` expression collapses to `$null`**, and
   every `.Count` on it then failed under `Set-StrictMode`. The profile block
   was being built from a null line array.

2. **`-ErrorAction SilentlyContinue` leaks the error record.** A failed launch
   recorded two errors where only one was meaningful: the visible message told
   the user how to install the agent, but `$Error` held a
   `CommandNotFoundException` above it. Every lookup where absence is an
   expected answer now uses `-ErrorAction Ignore`, which records nothing.
