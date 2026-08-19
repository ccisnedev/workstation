# 2. The workstation never owns what it did not create

Date: 2026-08-19

## Status

Accepted

## Context

The first version of this configuration deployed by replacing the directories
the tools read from. It linked `%LOCALAPPDATA%\nvim` and `~/.config/wezterm` to
the repository, moving whatever was there into a backup folder first.

On a machine with no Neovim and no WezTerm that is invisible. On anyone else's
machine it is a takeover: a tool asked to set up a workspace silently displaces
an editor configuration the user may have spent years on.

MACSS already answered this question for the same class of operation. Its skill
deployer writes only inside a prefix it owns:

> `const macssSkillNamespace = 'macss-';`
>
> *It marks what MACSS owns and may therefore retire. Skills without it belong
> to another tool or to the user, and are never touched.*

Nothing in the workstation had an equivalent boundary.

## Decision

Every path this repository writes to must be a path this repository is the sole
author of. Concretely:

1. **Neovim** is deployed under its own application name. `NVIM_APPNAME` is set
   to `workstation`, so the configuration is read from
   `%LOCALAPPDATA%\workstation` on Windows and `$XDG_CONFIG_HOME/workstation`
   elsewhere. Plain `nvim` keeps reading the user's own configuration, and the
   plugin data lands in a separate `workstation-data` directory.

2. **WezTerm** is not linked at all. `Start-Workstation` passes the
   configuration explicitly with `wezterm --config-file`, so a plain `wezterm`
   is unaffected.

3. **The PowerShell profile** is a file, and a link can only replace a
   directory. It is edited instead: a block delimited by
   `# >>> workstation >>>` and `# <<< workstation <<<` is inserted or
   refreshed, and everything outside the markers is copied through untouched.

4. Where a real directory is found at a path we do own, it is moved aside with
   a `.backup-<timestamp>` suffix rather than deleted, and the move is named in
   the plan before it happens.

## Consequences

**The workstation can be installed on a machine that already has a Neovim
setup**, which is the only way it can ever ship to someone other than its
author.

**Two Neovim configurations coexist on the machine**, and that is the point.
The cost is that a change made in the workstation editor does not improve the
user's own `nvim`, and the other way round. That is a fair price for not
destroying anything.

**Uninstalling is a two-line edit and a link removal.** Nothing has to be
restored, because nothing was replaced.

## References

- `ccisnedev/macss`, `code/cli/lib/modules/skill/deployer.dart`
- `ccisnedev/macss`, `docs/adr/0003-macss-owns-the-software-lifecycle.md`, point 4
