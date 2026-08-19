# Architecture

How the pieces fit together, and why each one is shaped the way it is.

---

## The problem

Configuring a machine normally scatters files across directories each tool picks
for itself. Afterwards there is no way to say what was changed, no way to review
it, and no way to reproduce it somewhere else. The configuration exists, but it
is not a thing you can reason about.

This repository inverts that. The files live here, under version control, and
the machine is made to point at them.

---

## Declared state

`code/powershell/Workstation/DeclaredState.psd1` is the source of truth. It
describes how a machine must look:

- **Tools** — what has to be on `PATH`, and the command to install each one
- **Links** — which directories must point back into this repository
- **PowerShell profile** — the marked block that loads the module
- **Agents** — which AI agents are expected

`Install-Workstation` reads that file and converges the machine towards it.
Nothing happens that is not declared, so adding a tool to the workstation is
adding a line, not writing a script.

The file is data only. `Import-PowerShellDataFile` parses it in restricted
language mode, so nothing inside it can execute.

---

## Links, and why junctions

A link entry makes the machine point at this repository:

```
%LOCALAPPDATA%\workstation   ->   code/assets/neovim
```

A link is not a copy. It is the same directory seen from two paths. Editing the
deployed `init.lua` and editing the repository's `init.lua` are the same act, so
`git status` sees the change immediately and drift between the two is not
possible — there is only one file.

On Windows the link is a **junction**, not a symbolic link. Symbolic links on
Windows require administrator rights or Developer Mode; junctions require
neither, and behave identically for a directory. On Linux and macOS the link is
an ordinary symbolic link.

The trade-off: a junction only links directories, never single files. That is
why the PowerShell profile is handled differently.

---

## Never owning what we did not create

This is the constraint that shapes everything else, and it is recorded in
[ADR 0002](adr/0002-the-workstation-never-owns-what-it-did-not-create.md).

Every path written to must be one this repository is the sole author of.

**Neovim** uses `NVIM_APPNAME`. When that variable is set to `workstation`,
Neovim reads its configuration from `%LOCALAPPDATA%\workstation` instead of
`%LOCALAPPDATA%\nvim`, and keeps its plugin data in `workstation-data`. The
launcher sets it for the editor pane only. A plain `nvim` anywhere else on the
machine still reads whatever the user already had.

**WezTerm** is not linked at all. `Start-Workstation` runs
`wezterm --config-file <repo>/code/assets/wezterm/wezterm.lua`, so the
configuration is chosen per launch rather than installed.

**The PowerShell profile** is a single file, so a link cannot help. The
installer edits it instead, inserting or refreshing a block between two markers:

```powershell
# >>> workstation >>>
Import-Module '<repo>/code/powershell/Workstation' -ErrorAction SilentlyContinue
# <<< workstation <<<
```

Everything outside those markers is copied through untouched. Writing the block
twice produces the same file, and removing the workstation is deleting three
lines.

---

## Preferences: taste, resolved separately

Architecture and taste have opposite properties. Architecture is a contract:
changing it changes what gets written to a machine, so it must be reviewed and
identical everywhere. Taste is a default: changing it changes how the workspace
looks, so it must be overridable per machine without touching a shipped file.

They therefore live in different files, resolved by different rules.

```
Preferences.psd1                          shipped defaults
        +
%LOCALAPPDATA%\workstation.preferences.psd1     this machine's override
$XDG_CONFIG_HOME/workstation.preferences.psd1
        |
        v  merged section by section
   resolved preferences
        |
        v  compiled
   preferences.lua                        machine output, outside the repository
        |
        +--> init.lua       via WORKSTATION_PREFERENCES
        +--> wezterm.lua
```

Merging is **by section**. An override naming one colour keeps every value it
did not mention. Replacing whole sections would make a one-key override silently
drop the rest, which is the failure mode that teaches people to stop writing
override files and start editing shipped ones.

Neither Lua file can read a PowerShell data file, so the resolved result is
compiled into a Lua table. Both load it and merge it over defaults compiled into
themselves, so the workspace still opens on a machine where nothing has been
generated yet — a fresh clone, or `wezterm --config-file` run by hand.

Generating it is a step like any other: it appears in `-Plan`, it is compared by
content rather than presence, and it is idempotent. Numbers are written with the
invariant culture, because on a machine with a comma decimal separator `0.38`
would otherwise become `0,38` and Lua would read a table with two values in it.

### The seams

Both inputs can be pointed elsewhere by an environment variable:

| Variable | Redirects |
|---|---|
| `WORKSTATION_DECLARED_STATE` | the declared state |
| `WORKSTATION_PREFERENCE_DEFAULTS` | the shipped preference defaults |
| `WORKSTATION_PREFERENCE_FILE` | the machine override |

These exist because `macss workstation` will ship its assets from its own tree,
and because a test must assert against a state it controls rather than whatever
the machine happens to have installed. The full reasoning is in
[ADR 0005](adr/0005-architecture-and-preference-are-different-things.md).

---

## Steps: one list for both preview and change

`Get-WorkstationStepList` builds one list. Each entry carries a state, a
human-readable description, and — when there is something to do — the action
that does it.

```
State      Meaning
---------  ------------------------------------------------------------
InSync     Matches the declared state. No action attached
Pending    Differs. An action is attached
Missing    Absent and not ours to install. Reported with its install command
Blocked    Something upstream prevents the step
```

`-Plan` prints the list. `-Apply` prints the same list and then invokes the
actions. There is no flag threaded through the work deciding whether to describe
or to do, so the preview cannot describe a change other than the one that
happens. The reasoning is in
[ADR 0003](adr/0003-plan-and-apply-are-mandatory-for-every-mutating-command.md).

Each action is a closure created with `GetNewClosure()`, capturing the exact
values that were printed. A closure runs in a fresh dynamic module and cannot
see the module's private functions, so actions use only built-in cmdlets, .NET
calls, and locals captured when the step was built. That constraint is the price
of the guarantee.

---

## Cross-platform

| Concern | Windows | Linux and macOS |
|---|---|---|
| Link type | Junction | Symbolic link |
| Neovim config path | `%LOCALAPPDATA%\workstation` | `$XDG_CONFIG_HOME/workstation` |
| Editor and agent panes | `pwsh.exe -NoExit -Command` | `/bin/bash -lc '…; exec /bin/bash'` |
| Bottom shell pane | PowerShell 7 | The user's login shell |
| Tool installation | winget, only with `-InstallMissingTools` | Reported, never executed |

The platform branch lives in two places only: `Get-WorkstationStepList` in the
module, and a single `is_windows` check in `wezterm.lua`.

Installing tools is deliberately asymmetric. On Windows there is one package
manager the machine certainly has. On Linux there is not, and guessing between
apt, pacman, dnf and brew would be inventing a default rather than deriving one,
so the install command is printed for a human to run.

---

## What is not in the repository

| Outside | Why |
|---|---|
| `%LOCALAPPDATA%\workstation-data` | Downloaded plugins. Rebuilt from `lazy-lock.json` |
| `.workstation/plans/` | Plan files describe one machine at one moment. Output, not source |
| The AI agents | Each needs an interactive sign-in |
| Credentials of any kind | Never belong in a repository |

`code/assets/neovim/lazy-lock.json` **is** committed, on purpose. It pins the
exact revision of every plugin, and is what makes a second machine resolve the
same versions instead of whatever is current that day.

---

## Where this is going

The target is the `macss workstation` module in `ccisnedev/macss`. The mapping
is fixed in [ADR 0004](adr/0004-this-repository-is-a-laboratory.md) so the port
stays mechanical, and the naming avoids `environment`, which MACSS reserves for
dev, uat, prod and demo.
