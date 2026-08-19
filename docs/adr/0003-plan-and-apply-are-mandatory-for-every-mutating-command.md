# 3. Plan and apply are mandatory for every mutating command

Date: 2026-08-19

## Status

Accepted

## Context

MACSS requires that every command which changes something take `--plan` or
`--apply`, and that neither be a default: a bare invocation is an error that
asks you to choose.

This repository is the laboratory for a MACSS command. A laboratory that does
not rehearse the discipline it exists to rehearse produces a result that cannot
be ported.

The first version of the installer used PowerShell's `-WhatIf`. That is the
right idea with the wrong default: without the flag it applies, so the safe
mode is the one you have to remember.

## Decision

`Install-Workstation` takes `-Plan` or `-Apply`. Neither is a default, and
passing both is an error.

- `-Plan` computes the steps, prints them, writes a plan file under
  `.workstation/plans/`, and touches nothing else.
- `-Apply` computes the same steps, prints them, asks once, and performs them.
  `-AutoApprove` skips the question for unattended runs.
- `Test-Workstation` takes neither, because it only reads.

The preview and the change are produced from **one list of steps**. `-Plan`
prints the list; `-Apply` prints the same list and then invokes the action
attached to each entry. There is no flag threaded through the work deciding
whether to describe or to do.

## Consequences

**The preview cannot describe a change other than the one that happens**, since
there is one description and one action per step, built together.

**Every step's action is a closure**, capturing the exact values that were
printed. A closure runs in a fresh dynamic module and cannot see the module's
private functions, so actions are restricted to built-in cmdlets, .NET calls,
and locals captured at build time. That is a real constraint on how steps are
written, accepted in exchange for the guarantee above.

**A bare `Install-Workstation` fails**, and that is the whole point: nobody
converges a machine by muscle memory.

## References

- `ccisnedev/macss`, `docs/adr/0007-plan-and-apply-are-mandatory-for-every-mutating-command.md`
- `ccisnedev/macss`, `code/cli/lib/modules/skill/deployer.dart`, on why a dry-run
  flag threaded through the work is only as faithful as its last editor
