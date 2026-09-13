# Testing

Seven suites live in `code/powershell/Workstation/Tests/`. They derive their
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
pwsh -File ./code/powershell/Workstation/Tests/Invoke-DocumentationQA.ps1
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

Windows 11 Pro 10.0.26220, PowerShell 7.6.5:

| Suite | Assertions | Result |
|---|---|---|
| `Invoke-DocumentationQA` | 16 | all passed |
| `Invoke-ToolPolicyQA` | 66 | all passed |
| `Invoke-PreferenceQA` | 86 | all passed |
| `Invoke-WindowsQA` | 75 | all passed |
| `Invoke-LaunchQA` (four agents) | 49 | 45 passed in full on 2026-08-26; the four title assertions since added were verified with one manual launch and await a full run |

**292 assertions**, as of 2026-09-12, on version 0.2.0. The launch suite
closes every WezTerm window on the machine, so it is run from a terminal
outside any workstation, never from inside one.

Ubuntu 24.04.4 (WSL2), PowerShell 7.4.6, Neovim 0.9.5, WezTerm 20240203, under
Xvfb:

| Suite | Assertions | Result |
|---|---|---|
| `Invoke-DocumentationQA` | 16 | all passed |
| `Invoke-ToolPolicyQA` | 66 | all passed |
| `Invoke-PreferenceQA` | 65 | all passed |
| `Invoke-LinuxQA` | 68 | all passed |
| `Invoke-LinuxLaunchQA` (four agents) | 51 | all passed |

**266 assertions, all green**, as of 2026-08-26, on version 0.2.0. The
preference and launch suites have grown since and have not been re-run there.

And on the real Wayland display, which is where the launch suite used to lose
windows: **59 assertions, green, three runs running** — twelve launches, none
lost. It had been two of four. See defect 20.

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
| `Uninstall-Workstation` | Plan and apply are mandatory here too; a plan removes nothing; an apply removes the link, the generated artifact and the marked block while keeping the user's own profile lines; the repository assets survive the link removal; a real directory at our link path is refused rather than deleted; a second uninstall is a no-op; installing again puts everything back |

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
| Unknown keys | An override key or section the shipped defaults do not declare is warned about by name, is not carried into the resolved result, and never reaches the compiled artifact. Singular and plural are asserted separately, because the grammar branches |
| Identity | The module WezTerm loads beside its configuration is run through Neovim's Lua, with no window: the project name is the last path component on Windows and POSIX paths alike; the title is the project name alone; the accent is one of the resistor colour code's ten, the same for a directory whatever its case or separators; a pin by project name wins, case-insensitively, and a pin that is not a hex colour is ignored; text on the accent is light or dark by luminance |
| Project colours | `ProjectColors` is an open section: a pin is not reported as unknown while a typo beside it still is; the pins reach the resolved result and the compiled artifact with their names verbatim and quoted, never snake-cased; Lua reads them back from the compiled file; WezTerm loads the configuration as a workstation, pins in place, without error |
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
| The launch gate | `Start-Workstation` refuses when a tool marked `Required` is absent, names it and its install command, and launches nothing |
| A malformed declared state | Every missing key is named at once, along with the file and the seam that redirected it |

### `Invoke-DocumentationQA` — cross-platform

The prose and the code, required to agree. Needs nothing but PowerShell, so it
runs in CI.

| Group | Covers |
|---|---|
| The code and its pages | Every state a step can hold appears in architecture.md; every exported command appears in the README and is explained somewhere |
| The ADRs | Each has Status, Context, Decision and Consequences; ADR 0001's stated count is how many there are; a decision narrowed by a later one says so in its own Status; every ADR link resolves to a file |
| The numbers | The README's per-suite counts sum to the total it claims; the declared state and the manifest state the same version, which nothing else keeps in step |

### `Invoke-LaunchQA` and `Invoke-LinuxLaunchQA`

Opens the workspace once for each of **claude, codex, antigravity and
opencode**, and for each asserts that WezTerm launched with this repository's
configuration and survived startup, that the editor pane runs Neovim under
`NVIM_APPNAME=workstation`, that the agent pane runs the right command and keeps
its shell, that the bottom pane is a plain shell, that the agent and editor
processes were started by that launch, and that the window closes cleanly. The
Windows suite also reads the window title back from the process and requires
it to be the project name, which is what the taskbar and Alt+Tab show.

Then that the plugin data landed in the workstation's own directory rather than
the user's, and that the launch environment variables were cleared from the
calling session.

Processes are keyed by pid, never by command line: two panes can run
byte-identical commands, and diffing on the text silently loses the second one.
This machine runs 29 `pwsh.exe` at rest, most of them byte-identical editor
shells, so the difference is not theoretical.

Both suites also count the panes by parent process and require exactly three,
and look for the agent and for Neovim *beneath their own pane* rather than
anywhere on the machine. With fourteen `claude.exe` running from unrelated
terminals, asking whether a process of that name exists answers nothing.

On Wayland the Linux suite also asserts that the window survived, andthat it was not maximised. The first is the outcome that matters and the
second is the one that cannot be fooled by luck: the race is intermittent, so
a green survival run proves little on its own, while the window is born 50
rows tall and a maximised one here is far taller.

And both assert that no pane is born too narrow for an agent to start in.
Linux reads the size from the pane's own terminal; Windows reads the size the
console host was created with, which is the one that matters because startup
is when an agent that cannot fit dies. The floor is 60 columns, chosen with
margin over the 40 that was measured.

---

## Continuous integration

`.github/workflows/qa.yml` runs on every push to `main` and on every pull
request. It carries the checks that need nothing but PowerShell:

| Check | Catches |
|---|---|
| Every source file parses | A syntax error committed between full runs |
| The data files load in restricted mode | A declared state or preference file that fails at run time on every command |
| The declared state has the required shape | A key removed from a file the module reads unguarded |
| No carriage returns survived the checkout | Defect 7's neighbourhood: the generated preferences carry the module file's line endings |
| The manifest and the module export the same functions | A command added to one list and not the other, which produces a command nobody can call |

Then `Invoke-ToolPolicyQA` on `ubuntu-latest` and `windows-latest`. It is
entirely fixture-driven, installs nothing, and touches no real path but the
plan file, which is what makes it the one suite that can run unattended.

**A green run there means less than a green run here.** The launch suites need
a display, WezTerm, Neovim and four agents that each require an interactive
sign-in, and they are the suites that have caught the most interesting defects
in this repository: the Wayland startup race, the codex shim, the pane that had
died and was being counted as alive. `Invoke-WindowsQA` and `Invoke-LinuxQA`
are absent for a smaller reason — they would run on a throwaway runner, but
they need Neovim and Git present to mean anything, and provisioning that on
every push has not been paid for yet.

The workflow says all of this in its own header, so nobody reads the badge as
more than it is.

---

## What is not covered

**macOS.** Not tested at all, and therefore not supported. It takes the same
code path as Linux, which makes it plausible and not proven — and the places
the two diverge, the configuration directory and the window behaviour, are
exactly the places a difference would hide. Tracked in
[issue #4](https://github.com/ccisnedev/workstation/issues/4).

**Wayland beyond this compositor.** Defect 20 stops the workspace maximising
on Wayland, on evidence from one compositor. Another may handle it perfectly
well, and there the window will simply not fill the screen. That asymmetry was
chosen deliberately; it is not knowledge.

**The race itself.** Nothing here fixes `xdg_wm_base error 4`. The workspace
stops walking into it, which is not the same thing, and a user who sets
`MaximizeOnStart` on a Wayland session they trust walks into it again.

**Key bindings.** The suites assert that `init.lua` loads without error, that
preferences reach it, and that plugins resolve. They do not assert that
`Space` + `E` opens the tree. That is left to daily use, which is what this
laboratory is for.

**Colours as rendered.** A preference is proven to reach WezTerm and Neovim as a
value. Nobody has asserted a pixel.

---

## What the suites have caught

Twenty-three defects so far. Most were found by an assertion rather than by using
the tool; two were found by using it, which is its own lesson; and the rest
were found by writing an assertion for something that had never had one, or by
sharpening one that could not fail.

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

13. **The Windows launch suite diffed processes by their command line.** The
    Linux suite had learned to key on pid — *two panes can run byte-identical
    commands, and diffing on the text silently loses the second one* — and the
    Windows one still compared strings. It runs on a machine with 29 `pwsh.exe`
    at rest, most of them identical editor shells, so any new pane whose
    command line matched an existing process vanished from the difference.
    **Fixed**: keyed on pid, like its counterpart.

14. **A launch assertion passed whether or not anything launched.** *The
    'claude' process is running* asked the machine whether a process of that
    name existed anywhere. There are fourteen at rest here, from terminals that
    have nothing to do with the workstation. **Fixed**: the agent is looked for
    beneath the pane that was supposed to start it. Sharpening it immediately
    turned up what it had been hiding — `codex` on Windows is a shim that runs
    node, so the pane's agent sits two levels down and the assertion had never
    once checked codex. The walk is now transitive.

15. **A missing Neovim was the only required thing nobody checked.**
    `Start-Workstation` refused a missing agent, and refused a missing WezTerm,
    and said nothing about a missing editor: the window opened and the pane
    failed inside it, where the message is easy to miss and impossible to act
    on. **Fixed**: every tool the declared state marks `Required` is checked by
    one rule.

16. **A malformed declared state failed opaquely.**
    `WORKSTATION_DECLARED_STATE` is a documented seam, so the file may well be
    one someone wrote this morning, and a missing key surfaced under
    `Set-StrictMode` as *The property 'Tools' cannot be found on this object* —
    naming neither the file, nor the seam, nor what was expected. **Fixed**:
    the shape is checked on read and every missing key is reported at once.

17. **An assertion asked the machine what it should have asked the call.**
    *Nothing was launched* was written as "no `wezterm-gui` is running
    anywhere", so it went red the moment a developer had a terminal open for
    their own reasons — and it would have gone green for the wrong reason too,
    on a machine that simply had none. **Fixed**: the processes are compared
    around the call. It is the same mistake as 14, made while fixing 14.

18. **A mistyped preference was compiled into the artifact.** `Preferences.psd1`
    is the list of what can be set, and the merge carried an override key
    through whether or not the defaults declared it. So `FontSizes = 20.0`
    written for `FontSize` did not merely fail to apply — it arrived in
    `preferences.lua` as `font_sizes = 20.0`, and a mistyped section arrived
    there whole, as `editorr = { tab_width = 8 }`. Both are read by nothing.
    The only symptom available to the person who wrote it was that the
    preference they meant had not changed. **Fixed**: the resolved result has
    the shape of the shipped defaults and nothing else, and every key that
    named nothing is warned about by name — dropping them silently would only
    have traded one quiet failure for another.

19. **The workspace opened too small for one of its own agents.** WezTerm's
    default window is 80 columns, the agent pane is 38% of the width, so the
    agent was handed a 30-column terminal. opencode crashes outright at that
    size — `SIGILL`, exit 132 — while claude, codex and antigravity tolerate
    it; bisecting put the floor between 30 and 40 columns, and height turned
    out not to matter at all. Its pane then execed into a plain shell, which
    reads exactly like a healthy bottom pane, so the workspace looked fine.

    Maximising was supposed to make the window big. It cannot be relied on for
    that: it is deferred past the first buffer commit because calling it from
    `gui-startup` races the compositor and kills the window on Wayland (defect
    3), and under a software-rendered display it may never land at all.

    This sat for days as *two red assertions caused by a third-party TUI*,
    which is what it looked like from the outside. It was ours. **Fixed**: the
    window is born at 200x50, so the narrowest pane clears the measured floor
    with room to spare, and the maximise goes back to being the improvement it
    always was rather than the thing correctness rested on. The size is a
    constant and deliberately not a preference — a value someone could lower
    to 80 would bring the defect straight back.

20. **The window was maximised into its own destruction, and the comment
    explaining why was wrong three times over.** On Wayland, maximising takes
    the window out often enough to have cost two launches of four in a measured
    run: the compositor configures a maximised state, WezTerm commits a buffer
    that does not match it, and the protocol error terminates the process.

    The code carried an explanation that said the surface was *"still at its
    default size"* (the buffer was 1816x1116 — the whole window), that
    deferring past the first buffer commit *"avoids the race"* (it was deferred
    for both failures), and that `pcall` kept any remaining failure *"cosmetic
    rather than fatal"* (`pcall` catches Lua errors; this is a protocol error
    that takes the process with it). A confident wrong comment is worse than
    none: it is what stopped anyone looking again.

    What changed underneath it is the arithmetic. Maximising used to be
    load-bearing — the window opened at 80x24 and the panes were unusable
    until it grew. Since defect 19 the window is born large, so maximising buys
    the window filling the screen and nothing else, and it was being paid for
    with half the launches. **Fixed**: skipped on Wayland. Twelve launches
    since, none lost.

21. **The version marker was the one value an override could forge.** `Schema`
    describes the shape of the shipped preferences, which makes it the one key
    an override has no business setting — and it was the one key an override
    could set in silence, because being declared in the defaults made it count
    as known. A machine could compile `schema = 99` into `preferences.lua`, and
    the only reader that will ever care about that number is whatever migrates
    an old override one day. **Fixed**: keys that describe the shipped file are
    taken off the override before anything merges it, and reported as
    unsettable rather than as unknown — told the wrong one, the reader goes
    hunting for a typo that is not there.

22. **A rule that named no tool, except one.** `Start-Workstation` refuses to
    launch when a tool marked `Required` is missing, and skipped one by name,
    because WezTerm on Windows is not on `PATH` and its install location was
    written into the launch code. The rule therefore read *every required tool
    except one called WezTerm*, in a module that otherwise refuses to hardcode
    a name. **Fixed**: where to find a tool `PATH` cannot answer for is
    declared, `Resolve-DeclaredTool` consults it, and which tool is the
    terminal is a declared `Role` rather than a string in a comparison. In
    passing, Git declared `Purpose = 'Required by the Neovim plugin manager'`
    while carrying no `Required` flag; the prose now says what it does.

23. **The documentation drifted and nothing went red.** A fifth step state was
    added and the table listing them was not. ADR 0001 said the port costs a
    review of *four* ADRs long after there were six. ADR 0002 promised that
    uninstalling restores nothing because nothing was replaced, which ADR 0006
    had made untrue, with no pointer from the page a reader actually lands on.
    All three were found by writing `Invoke-DocumentationQA` and running it
    once. **Fixed**, and now asserted: the prose and the code have to agree.
