# Testing

Six suites live in `code/powershell/Workstation/Tests/`. They derive their
paths from `$PSScriptRoot`, so they run from any clone, on any machine.

They are not unit tests. They install, break, repair and uninstall the
workstation on the machine that runs them, and assert against the real
filesystem and real processes — which is the only way to test a thing whose
whole job is to change a machine.

---

## Running them

```powershell
# Windows
pwsh -File ./code/powershell/Workstation/Tests/Invoke-WindowsQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-PreferenceQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-ToolPolicyQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LaunchQA.ps1

# Linux and macOS
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LinuxQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-PreferenceQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-ToolPolicyQA.ps1

# The Linux launch suite needs a display. On a headless machine:
xvfb-run -a --server-args="-screen 0 1920x1080x24" \
    pwsh -File ./code/powershell/Workstation/Tests/Invoke-LinuxLaunchQA.ps1
```

Each exits with the number of failed assertions, so `$LASTEXITCODE` is usable as
a gate.

Every suite creates its own fixtures — a decoy user Neovim configuration, a
decoy WezTerm configuration, a user line in the PowerShell profile, a declared
state naming tools that cannot exist — and removes them at the end. Each leaves
the workstation installed and on the shipped defaults.

Since [ADR 0006](adr/0006-installing-a-declared-tool-is-an-ordinary-step.md) an
apply installs missing tools, so the two suites that apply against the real
declared state — `Invoke-WindowsQA` and `Invoke-PreferenceQA` — run with its
`Tools` block emptied through `WORKSTATION_DECLARED_STATE`. They verify the
block really was emptied before they proceed and abort if it was not, because
the failure mode there is installing software on someone's machine rather than
a red assertion. **No suite installs anything.**

---

## Results

Both platforms, re-run in full after ADR 0006 and the defect fixes below.

Windows 11 Pro 10.0.26220, PowerShell 7.6.5:

| Suite | Assertions | Result |
|---|---|---|
| `Invoke-ToolPolicyQA` | 49 | all passed |
| `Invoke-PreferenceQA` | 48 | all passed |
| `Invoke-WindowsQA` | 58 | all passed |
| `Invoke-LaunchQA` (four agents) | 33 | all passed |

**188 assertions, all green**, as of 2026-08-20.

Ubuntu 24.04.4 (WSL2), PowerShell 7.4.6, Neovim 0.9.5, WezTerm 20240203, under
Xvfb:

| Suite | Assertions | Result |
|---|---|---|
| `Invoke-ToolPolicyQA` | 49 | all passed |
| `Invoke-PreferenceQA` | 48 | all passed |
| `Invoke-LinuxQA` | 52 | all passed |
| `Invoke-LinuxLaunchQA` (four agents) | 43 | 41 passed, **2 failed** |

**192 assertions, 190 green**, as of 2026-08-20. The two failures are `N04.3`
and `N04.5`: under Xvfb the opencode pane exits at once, so the pane it leaves
behind is a plain shell. It is not the launcher. All three panes are created —
the pane count asserts that independently — opencode survives a login shell
under a pty outside the harness, and on the real display the same suite passes
every opencode assertion. What it does not survive is a small,
software-rendered terminal, which is what Xvfb gives it. Recorded rather than
suppressed, because a red assertion nobody can explain is worth more than a
green one nobody checked.

Run on a Linux checkout, not over `/mnt/c`. `X05` asserts the working tree has
no carriage returns, and a Windows checkout read through WSL fails it
correctly: `.gitattributes` gives each platform its own endings, and the suite
is entitled to expect the Linux ones.

---

## What they assert

### `Invoke-WindowsQA` and `Invoke-LinuxQA`

The deployment contract, on each platform.

| Group | Covers |
|---|---|
| Command contract | A bare `Install-Workstation` fails; `-Plan -Apply` together fails; `Test-Workstation` takes neither; an undeclared agent is rejected by the binder; a non-existent directory raises exactly one error |
| Plan writes nothing | After `-Plan`, no link and no profile block exist; one plan file is written naming the pending work |
| Apply and idempotency | The link is a junction on Windows and a symbolic link on Linux, pointing at the assets; a second apply changes nothing; a plan afterwards reports zero pending |
| Round trip | Editing through the link appears in `git status`; `git checkout` reverts the file as seen through the link |
| Never owning | A pre-existing user Neovim config survives byte-for-byte; the user WezTerm directory is never linked; user lines in the profile survive; the marked block appears exactly once |
| Drift and repair | A deleted link is detected and repaired; a link pointing elsewhere is named, repointed, and the decoy survives; a real directory is backed up rather than deleted; a corrupted profile block is restored without losing user content |
| Declining | Answering no to the confirmation writes nothing |
| Uninstall and reinstall | Three full cycles, each returning to fully in sync |

The Linux suite adds what only Linux can answer: the profile path, `XDG_CONFIG_HOME`
resolution, `fd` found under its Debian name `fdfind`, `.gitattributes`
normalisation, and that `NVIM_APPNAME=workstation` resolves to the deployed
directory while plain `nvim` resolves elsewhere.

### `Invoke-PreferenceQA` — cross-platform

The preference architecture, and the point of it: that taste is resolved
separately from architecture and actually reaches the running programs.

| Group | Covers |
|---|---|
| Separation | Declared state and preferences are two files; no taste leaked into the declared state; the preferences carry a schema version |
| Resolution | Shipped defaults resolve; the default agent comes from the preferences and is one the declared state supports |
| Merging | An override changes the key it names, keeps its siblings, keeps untouched sections, and never modifies the shipped file |
| The artifact | Compiled to snake case with Lua booleans; marked as generated; lands outside the repository |
| Locale | A fractional preference is written `0.45` and never `0,45`, which Lua would read as two values |
| Drift | Changing an override marks the artifact pending and says *refresh*; applying brings it in sync; a second apply regenerates nothing |
| Into the editor | `TabWidth = 8` arrives in Neovim as `shiftwidth`; startup carries no configuration error; the syntax plugin exposes the API the config calls |
| Into the terminal | `FontFamily = 'Consolas'` shows up in `wezterm ls-fonts` |
| Reverting | Removing the override returns the resolved values and the compiled file to the defaults |
| Fallback parity | Every shipped default is compared, key by key, against the `DEFAULT_PREFERENCES` table in each Lua file, using the module's own compiler to render the expected literal |
| Seams | `WORKSTATION_PREFERENCE_FILE` and `WORKSTATION_DECLARED_STATE` redirect their inputs; against a fixture declaring a tool that cannot exist, the advice carried is **this** platform's and never the other's, and reading the step list never installs it |

### `Invoke-ToolPolicyQA` — cross-platform

The tool-installation policy of
[ADR 0006](adr/0006-installing-a-declared-tool-is-an-ordinary-step.md). Every
assertion runs against a declared-state fixture, so the suite installs nothing
and touches no real path but the plan file.

| Group | Covers |
|---|---|
| The flag is gone | `Install-Workstation` has no `-InstallMissingTools`; `Get-WorkstationStepList` takes no parameters at all, so plan, apply and check cannot build different lists; neither the module nor the declared state still names the flag |
| An ordinary step | A missing tool is `Pending` with an action where this machine can install it, and `Missing` with **this** platform's hint where it cannot |
| Building never acts | Ten step-list builds and a plan install nothing; the fixture names an identifier no source carries |
| Plan equals check | The rendered plan file is parsed back and compared, step by step, against what `Test-Workstation` returns |
| Defensive parsing | Install advice carrying no `--id` yields no identifier, so the step falls back to `Missing` rather than running an install with an empty identifier |
| Missing is drift | `Get-StepSummary` totals it; a list whose only difference is `Missing` still counts as drift; check no longer prints *In sync* while a tool is absent |
| The closing advice | A required tool that is neither in sync nor just installed withholds the invitation and names what is left; a tool installed by that very run counts as present, because it is not yet on the process's `PATH` |
| The apply uses it | A real apply over a fixture whose required tool cannot be installed performs its pending step, withholds the invitation, and names the tool |
| Failure is not success | A step whose action throws is marked `Failed` on the list the apply then reports from, counted as a failure and as drift, and a required tool that failed withholds the invitation. Driven by a link whose parent directory cannot be created, so no package manager and no network are involved |
| One is a collection | A single unsatisfied tool is still returned as a collection. PowerShell unrolls a one-element result out of a function, and the most common real shape is a machine missing exactly one tool |

### `Invoke-LaunchQA` and `Invoke-LinuxLaunchQA`

Opens the workspace once for each of **claude, codex, antigravity and
opencode**, and for each asserts that WezTerm launched with this repository's
configuration and survived startup, that the editor pane runs Neovim under
`NVIM_APPNAME=workstation`, that the agent pane runs the right command and keeps
its shell, that the bottom pane is a plain shell, that the agent and editor
processes were started by that launch, and that the window closes cleanly.

Then that the plugin data landed in the workstation's own directory rather than
the user's, and that the launch environment variables were cleared from the
calling session.

Processes are keyed by pid, never by command line: two panes can run
byte-identical commands, and diffing on the text silently loses the second one.

---

## What is not covered

**macOS.** Not tested at all. It takes the same branch as Linux, so it is
plausible rather than proven.

**opencode under Xvfb.** Its pane exits immediately and two assertions stay
red. The cause is outside this repository and is characterised above, but
nothing here proves it, so it is a known failure rather than a known cause.

**The real display on Linux.** `Invoke-LinuxLaunchQA` on WSLg loses the first
launch of the four to the Wayland startup race described in defect 3 and then
runs clean. Xvfb is the recorded path because it is the reproducible one; the
flake on a live compositor is real and unfixed.

**Key bindings.** The suites assert that `init.lua` loads without error, that
preferences reach it, and that plugins resolve. They do not assert that
`Space` + `E` opens the tree. That is left to daily use, which is what this
laboratory is for.

**Colours as rendered.** A preference is proven to reach WezTerm and Neovim as a
value. Nobody has asserted a pixel.

---

## What the suites have caught

Twelve defects so far. Most were found by an assertion rather than by using
the tool; two were found by using it, which is its own lesson; and four were
found by writing an assertion for something that had never had one.

1. **`@()` assigned from inside an `if` expression collapses to `$null`**, so
   every `.Count` on it failed under `Set-StrictMode`. The profile block was
   being built from a null line array.

2. **`-ErrorAction SilentlyContinue` leaks the error record.** A failed launch
   recorded two errors where one was meaningful: the visible message told the
   user how to install the agent, but `$Error` held a `CommandNotFoundException`
   above it. Lookups where absence is an expected answer now use
   `-ErrorAction Ignore`, which records nothing.

3. **Maximising the window raced the Wayland compositor.** Two of four launches
   died before any pane existed, with `xdg_wm_base error 4` and
   `Protocol error (os error 71); terminating`. Calling `maximize()` straight
   from `gui-startup` configures the maximised state while the surface is still
   at its default size. It is intermittent, so it reads as a flake. The call is
   now deferred past the first buffer commit and wrapped in `pcall`. Windows
   never hit it.

4. **nvim-treesitter had never been configured.** Its default branch is now the
   `main` rewrite, which removed `nvim-treesitter.configs`, so every startup
   failed with `module 'nvim-treesitter.configs' not found` and the editor ran
   with no syntax highlighting at all. It read as working because the rest of
   the configuration still loaded. The plugin is pinned to `master`.

5. **The suites depended on what happened to be installed.** Assertions written
   against a bare machine started failing the moment the launch tests installed
   WezTerm and the four agents — not because anything broke, but because the
   assertions asserted absence. They now assert the rule, and the platform-hint
   logic is proven against a declared-state fixture where absence is guaranteed.

Two of those were only visible because the assertion was widened after the
fact: the treesitter failure did not match the error pattern in use, and the
missing bottom pane was masked by keying processes on their command line. An
assertion that cannot fail is not evidence.

6. **A bare apply produced a machine that could not open.** It reported three
   tools missing, performed the three configuration steps, and closed with
   *Open a new terminal and run: `Start-Workstation`*. The next command failed
   with `WezTerm was not found`. Nothing caught it because `Missing` was
   counted nowhere: `Test-Workstation` ended with *In sync with the declared
   state* in green on that same machine. A state printed in red and totalled
   nowhere is a state the reader is invited to ignore, and so was the assertion
   that never existed for it. See
   [ADR 0006](adr/0006-installing-a-declared-tool-is-an-ordinary-step.md).

7. **The generated preferences depended on the checkout's line endings.** The
   desired content is built from a here-string in `Workstation.psm1`, so it
   carries whatever endings that file has, while `Set-Content` writes the
   platform's. Rewriting the module with LF endings on Windows made the
   *Resolved preferences* step pending forever: every plan claimed drift that
   was not there and every apply rewrote a file that had not changed. It was
   consistent as long as `.gitattributes` was honoured, which is why it had
   never shown. **Fixed**: the comparison now normalises line endings out of
   both sides, because what the step is about is content.

8. **A failed tool install was reported as done.** `winget` is a native
   command, so a non-zero exit does not throw and the `catch` around the step
   never fired. Every install printed `[done]` whatever happened. **Fixed**:
   the action asks the machine instead of the exit code — it refreshes `PATH`
   from the environment winget just wrote, which this process never re-reads
   on its own, and looks the command up again. That also accepts the case
   where the tool was already installed but absent from this session's `PATH`.

9. **The closing advice trusted the plan over the outcome.** A step kept the
   state the plan gave it, so a required tool whose install threw still read as
   `Pending`, and `Pending` counts as satisfied. The apply would print *Open a
   new terminal and run `Start-Workstation`* immediately after failing to
   install the terminal — the very defect ADR 0006 was written to remove,
   arriving by a second route. **Fixed**: a step whose action throws is marked
   `Failed` on the list, and everything printed afterwards is computed from
   that list.

10. **A one-element result stopped being a collection.** PowerShell unrolls a
    collection on the way out of a function, so `Get-UnsatisfiedRequiredTool`
    returned a bare step whenever exactly one required tool was missing, and
    every `.Count` on it threw under `Set-StrictMode` — in the most common real
    case there is. It surfaced as `PropertyNotFoundException` noise in a suite
    that was otherwise green, which is the only reason it was seen. **Fixed**
    with the unary comma, and asserted directly.

11. **A link target was compared case-insensitively on Linux.** A link to
    `~/code/Repo` would have been reported in sync with `~/code/repo` on a
    filesystem where those are two directories. **Fixed**: the comparison
    follows the platform.

12. **The bottom-pane assertion could be satisfied by a corpse.** Each agent
    pane runs `bash -lc '<agent>; exec /bin/bash'`, so an agent that dies is
    replaced in place by a plain shell that reads exactly like the bottom pane.
    The assertion counted plain shells and wanted at least one, so the bottom
    pane could have been missing entirely with nothing red to say so. It is
    what let opencode's dead pane look survivable. **Fixed**: the panes are
    also counted by parent process, and three is the shape of this workspace.
