# Testing

Five suites live in `code/powershell/Workstation/Tests/`. They derive their
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
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LaunchQA.ps1

# Linux and macOS
pwsh -File ./code/powershell/Workstation/Tests/Invoke-LinuxQA.ps1
pwsh -File ./code/powershell/Workstation/Tests/Invoke-PreferenceQA.ps1

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

---

## Results

| Suite | Platform | Assertions | Result |
|---|---|---|---|
| `Invoke-WindowsQA` | Windows 10 19045, PowerShell 7.6.4 | 57 | all passed |
| `Invoke-PreferenceQA` | Windows 10 19045 | 40 | all passed |
| `Invoke-LaunchQA` | Windows 10 19045, four agents | 33 | all passed |
| `Invoke-LinuxQA` | Ubuntu 22.04.5 (WSL2), pwsh 7.6.5, Neovim 0.12.4 | 52 | all passed |
| `Invoke-PreferenceQA` | Ubuntu 22.04.5 | 40 | all passed |
| `Invoke-LinuxLaunchQA` | Ubuntu 22.04.5, Xvfb, four agents | 39 | all passed |

**261 assertions, all green**, as of 2026-08-19. Windows 130, Linux 131.

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
| Seams | `WORKSTATION_PREFERENCE_FILE` and `WORKSTATION_DECLARED_STATE` redirect their inputs; against a fixture declaring a tool that cannot exist, it is reported missing with **this** platform's install command and never the other's |

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

**Key bindings.** The suites assert that `init.lua` loads without error, that
preferences reach it, and that plugins resolve. They do not assert that
`Space` + `E` opens the tree. That is left to daily use, which is what this
laboratory is for.

**Colours as rendered.** A preference is proven to reach WezTerm and Neovim as a
value. Nobody has asserted a pixel.

---

## What the suites have caught

Five defects so far, every one found by an assertion rather than by using the
tool.

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
