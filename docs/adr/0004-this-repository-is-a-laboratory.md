# 4. This repository is a laboratory, not a product

Date: 2026-08-19

## Status

Accepted

## Context

The workspace this repository builds — an editor, an AI agent and a shell in one
terminal — is the surface on which MACSS work actually happens. MACSS lists
"environment diagnostics and upgrade flows" in its CLI scope, already models
`claude` and `opencode` as installable hosts, already installs once per machine
into the user's home directory, and already targets Windows, Linux and macOS.
The workstation belongs there.

It does not belong there *yet*.

MACSS is in production and has to work for someone who installs nothing else.
What this repository holds today is two days old, untested on Linux, and half
personal taste: a colour scheme, a leader key, a particular file tree. Merging
that into a repository with 116 commits and ten ADRs would make a production
tool inherit an unproven dependency.

MACSS has already faced this exact shape and written the answer down:

> *inquiry is the laboratory where the method is refined under enforced gates;
> MACSS inherits the result when a human ports it into a skill.*
>
> *The cost is a manual sync point… This is deliberate: editorial, at human
> pace, decided by a person — and it is what buys MACSS the ability to stand
> alone.*

## Decision

This repository is the laboratory for the future `macss workstation` module.
The relationship is one-directional: MACSS never depends on this repository, and
inherits from it only when a human ports a decision.

The target shape is fixed now, so the port stays mechanical:

| Here | Becomes, in MACSS |
|---|---|
| `code/assets/` | `code/cli/assets/workstation/` |
| `code/powershell/Workstation/` | `code/powershell/`, the delegated engine |
| `Install-Workstation -Plan` / `-Apply` | `macss workstation deploy --plan` / `--apply` |
| `Test-Workstation` | `macss workstation check` |
| `Start-Workstation`, alias `ws` | a shim installed by deploy, as `ma` is for `macss` |

The word `environment` is deliberately **not** used. In MACSS it is already
spoken for: Stage 7 reserves it for dev, uat, prod and demo, and `code/infra`
uses `environments/` in that same sense. `workstation` names the machine a
person works at, which is a different thing from the environment the software
runs in.

For the same reason the assets do not go to `code/infra`. That module is
declared as "provisioning and deployment of the environments where the other
modules run"; a developer's editor is not where the modules run.

## Consequences

**Nothing here is a MACSS contract.** No command name, flag or file layout in
this repository binds MACSS. When the port happens it is free to differ.

**The port is a rewrite, not a move.** The MACSS CLI is Dart; this is
PowerShell. What crosses is the four ADRs and the asset tree. The PowerShell may
survive as the delegated engine under the `pwsh` boundary Stage 3.5 already
defines, or it may not.

**Maturity is decided by a human, not by a milestone.** The gate has three
conditions, and as of 2026-08-19 all three are met:

| Condition | State |
|---|---|
| Proven on Windows | Met — 130 assertions, including all four agents |
| Proven on Linux | Met — 131 assertions on Ubuntu 22.04, including opening the three-pane window for all four agents under Xvfb |
| Separated into architecture and taste | Met — see [ADR 0005](0005-architecture-and-preference-are-different-things.md) |

Meeting the gate is not the same as porting. What the gate says is that the
question is now editorial rather than technical: nothing here is unproven, so
the remaining decision is whether a workstation belongs in MACSS at all, and
that is a person's call made at a person's pace.

Two things are still not proven and should be said plainly rather than
discovered later: macOS is untested, and no assertion covers a key binding or a
rendered colour. Both are listed in [testing.md](../testing.md).

## References

- `ccisnedev/macss`, `docs/adr/0003-macss-owns-the-software-lifecycle.md`
- `ccisnedev/macss`, `docs/roadmap.md`, Stage 3.5 and Stage 7
- `ccisnedev/macss`, `code/infra/README.md`
