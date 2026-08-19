# 5. Architecture and preference are different things

Date: 2026-08-19

## Status

Accepted

## Context

[ADR 0004](0004-this-repository-is-a-laboratory.md) named three conditions for
porting this into `macss workstation`. Two were about proof. The third was not:

> Separated into architecture and taste — not met. The colour scheme, the leader
> key and the plugin set are one person's preference and are still mixed into
> the asset tree.

That is what actually blocked the port. MACSS is a production tool with ADRs and
a public CLI. It may ship an opinionated reference workstation, but it has to
know which parts are the opinion, because the two have opposite properties:

- **Architecture** is a contract. Changing it changes what gets written to a
  machine. It must be reviewed, versioned, and identical everywhere.
- **Taste** is a default. Changing it changes how the workspace looks. It must
  be overridable per machine without touching a shipped file.

Mixed together, neither can be treated correctly. A user who wants a different
colour scheme has to edit a file the repository owns, so the next `git pull` is
a conflict; and a reviewer reading a diff cannot tell whether a change alters a
contract or a colour.

## Decision

The two are separated into different files, resolved by different rules.

**`DeclaredState.psd1` holds architecture.** What must exist, where it is
linked, which paths this repository is allowed to write to, which agents are
supported. Nothing in it is a matter of preference.

**`Preferences.psd1` holds taste, and ships defaults only.** Colour schemes,
fonts, sizes, the leader key, pane proportions, the default agent.

**A machine overrides preferences in its own file**, never by editing the
shipped one:

    Windows   %LOCALAPPDATA%\workstation.preferences.psd1
    Linux     $XDG_CONFIG_HOME/workstation.preferences.psd1

Resolution is defaults first, override on top, **merged section by section**.
An override naming one colour keeps every value it did not mention. Replacing
whole sections would make a one-key override silently drop the rest, which is
the failure mode that teaches people to stop writing override files and start
editing shipped ones.

**The resolved result is compiled into a Lua table.** Neither Neovim nor WezTerm
can read a PowerShell data file, so `Install-Workstation` writes
`preferences.lua` and points `WORKSTATION_PREFERENCES` at it. Both Lua files
load it and merge it over defaults compiled into themselves, so the workspace
still opens on a machine where nothing has been generated yet.

**Generation is a step like any other.** It appears in `-Plan`, it is compared
by content rather than by presence, and it is idempotent. A preference changed
in an override file shows up as a pending step; the plan would otherwise claim a
machine is in sync while the editor is still painted in last week's colours.

**Both inputs can be redirected by an environment variable**:

| Variable | Redirects |
|---|---|
| `WORKSTATION_DECLARED_STATE` | the declared state |
| `WORKSTATION_PREFERENCE_DEFAULTS` | the shipped preference defaults |
| `WORKSTATION_PREFERENCE_FILE` | the machine override |

These are not conveniences. `macss workstation` will ship its assets from its
own tree rather than from here, and a test needs to assert against a state it
controls rather than whatever the machine happens to have installed. A seam
that exists only when someone remembers to add it does not exist.

## Consequences

**The port has a shape.** `macss workstation deploy` reads a declared state it
owns, resolves preferences with the same order, and compiles the same artifact.
What crosses is the resolution rule, not the values.

**Preferences are configurable today, in the only way that matters** — a user
can change every value without editing a file the repository owns — while the
values themselves are still hard-coded defaults. The architecture is finished;
the surface for editing it comfortably is not. A future `macss workstation set
editor.color-scheme catppuccin` writes the same override file this already
reads.

**The generated file must never be committed.** It lands outside the linked
configuration directory on purpose. Writing it inside would put machine output
into a declared-state repository, which is the one thing such a repository must
not contain.

**Two copies of the defaults exist**: `Preferences.psd1`, and the fallback table
at the top of each Lua file. They must stay in step, and nothing enforces it.
The alternative was a workspace that fails to open when the artifact is missing,
which is worse. The Lua fallbacks are marked as such and are the first place to
look when a default seems not to apply.

**Numbers are compiled with the invariant culture.** On a machine with a comma
decimal separator, `0.38` would otherwise be written `0,38`, and Lua would read
a table constructor with two values in it. This is asserted, not assumed.

## References

- `ccisnedev/macss`, `docs/adr/0009-a-default-may-derive-but-never-invent.md`
- `ccisnedev/macss`, `docs/adr/0007-plan-and-apply-are-mandatory-for-every-mutating-command.md`
