# 6. Installing a declared tool is an ordinary step

Date: 2026-08-20

## Status

Accepted

Supersedes the rule stated in the header of `DeclaredState.psd1`, which was
never given an ADR of its own.

## Context

The declared state carried two rules. The first — that the workstation never
owns what it did not create — is
[ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md). The
second was written beside it and cited nothing:

> Tools are detected and reported, never installed behind your back.
> `Install-Workstation -InstallMissingTools` is the only way anything reaches a
> package manager, and you have to ask for it.

Read on its own it sounds like caution. In practice it was a second consent
gate for a consent that had already been given, and it cost more than it
bought.

**It contradicted ADR 0003.** That decision says, of the plan and the apply:

> There is no flag threaded through the work deciding whether to describe or to
> do.

`-InstallMissingTools` was exactly such a flag, and worse than the kind ADR 0003
had in mind. It did not decide whether to act; it decided what the list
*contained*. `Install-Workstation -Plan` and `Install-Workstation -Plan
-InstallMissingTools` produced different plans of the same machine. The plan
file written under `.workstation/plans/` recorded the date, the repository and
the pending count, but not the flag, so two plans of one machine could disagree
with nothing on the page to explain why.

**It had already split the commands.** `Install-Workstation` built its list
with the flag; `Test-Workstation` built its list without one. Check and plan
could describe two different machines, and on a machine with missing tools they
did.

**The consent it was protecting was already being taken.** `-Apply` prints the
whole list and asks once. A step reading `install with winget: wez.wezterm` is
not a surprise; it is the least surprising thing on the page. Requiring a
second, differently-named permission for it taught the reader that the printed
list is not the whole story, which is the opposite of what ADR 0003 is for.

**And the machine it produced did not work.** A bare `-Apply` reported three
tools missing, performed the three configuration steps, and closed with
`Open a new terminal and run: Start-Workstation`. The next command failed:
`WezTerm was not found`. The installer had printed an invitation into a
workspace it knew could not open.

## Decision

Installing a declared tool is an ordinary step. It appears in the list that
`-Plan` prints and `-Apply` performs, on the same footing as a link or a
profile block, and the consent given to the list covers it.

1. **`-InstallMissingTools` is removed.** `Get-WorkstationStepList` takes no
   parameters at all, so `Install-Workstation` and `Test-Workstation`
   demonstrably build one identical list.

2. **What remains is a capability test, never a consent test.** A tool step is
   `Pending` when this machine can install it — on Windows, with `winget`
   present, and with an identifier that can be read out of the declared
   install advice. Otherwise it is `Missing`, which now means one thing only:
   *no package manager here can supply this, here is the command you would
   run*. On Linux nothing is ever executed, for the reason already given in the
   declared state: the correct package manager is not something this repository
   is entitled to guess.

3. **The identifier must parse.** Advice that is not a `winget install --id
   <identifier>` one-liner yields no identifier and the step falls back to
   `Missing`. A step whose action would run `winget install --id ''` is worse
   than no step at all.

4. **`Missing` counts as drift.** It is totalled by `Get-StepSummary` and
   reported by every command that reports a count. It used to be printed in red
   and counted nowhere, which let `Test-Workstation` end with *In sync with the
   declared state* in green on a machine with no terminal and no editor.

5. **The closing advice is derived from the list that was performed**, not from
   a fresh lookup. A tool declared `Required` that is neither `InSync` nor
   `Pending` withholds the invitation to `Start-Workstation` and names what is
   still missing instead. `Required` is declared in `DeclaredState.psd1` and
   travels on the step.

6. **Tools are installed, never uninstalled.** Removing the workstation removes
   what the workstation authored. A terminal is not that, and ADR 0002's
   boundary applies to it: we did not own it before we installed it, and we do
   not own it after.

## Consequences

**A plan is a property of the machine and the declared state, and nothing
else.** Two plans taken of one machine at one moment are the same plan. This is
what makes the plan file worth keeping.

**Check and plan cannot disagree.** They call one function with no arguments.

**Uninstalling no longer returns the machine to its prior state**, and that is
accepted rather than solved. Point 6 bounds it: the tools stay, they are named
in the plan before they arrive, and nothing removes them behind you. This is a
real weakening of ADR 0002's *"Nothing has to be restored, because nothing was
replaced"*, and it is confined to software the plan named and you approved.

**A QA suite that applies can no longer use the real declared state.** The
Windows and preference suites mutate the machine and promise to restore it, and
installing a terminal is not restorable. They run against the real declared
state with the `Tools` block emptied, through `WORKSTATION_DECLARED_STATE`, and
they verify the block really was emptied before they proceed — because the
failure mode there is installing software on someone's machine rather than a
red assertion.

**`-AutoApprove` now installs software unattended.** It skips the question, not
the plan, and that was always its meaning; the difference is what the list may
now contain. An unattended caller that does not want tool installs declares a
state without them, which is what `WORKSTATION_DECLARED_STATE` is for.

## References

- [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md), whose
  ownership boundary is narrowed here rather than abandoned
- [ADR 0003](0003-plan-and-apply-are-mandatory-for-every-mutating-command.md),
  on the single list, and on flags that decide describe-versus-do
- `code/powershell/Workstation/Tests/Invoke-ToolPolicyQA.ps1`, which asserts
  every point above
