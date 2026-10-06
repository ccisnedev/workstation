# 9. Sessions are hidden until they are shown

Date: 2026-10-05

## Status

Accepted

## Context

`ws -List` printed every conversation Claude Code had kept, across every
project, newest first. That was the whole of the feature when it was written,
and it was enough while the workstation was the only place claude ran. It is
not enough now: Claude is also started from other terminals, from editors and
from scripts, and each of those leaves a conversation in the same store. The
list the workstation prints fills with sessions that were never opened in a
workstation window, and the ones that were are the ones the person is looking
for.

Claude's store is not the workstation's. By
[ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md) nothing
there may be written, so "hiding" a session cannot be done by marking it, moving
it or deleting it. The mark has to live somewhere the workstation owns.

Claude Code offers two places a program can learn which session is running. The
status line command of [ADR 0008](0008-the-agent-pane-tells-the-status-bar-what-it-knows.md)
receives `session_id` in its payload, but only after a response, and hundreds of
times. A `SessionStart` hook receives the same `session_id`, once, when the
session begins, for every way a session can begin: startup, resume, clear,
compact and fork.

## Decision

A session is shown in `ws -List` when it started in a workstation window or when
the person showed it by hand. Every other session is hidden, and `-List -All`
still prints it.

1. **Hidden is the default.** The list is for finding what you were doing in a
   workstation. A list that must be filtered by hand to be useful is the list
   that was replaced. The cost is paid once: the first `ws -List` after the
   upgrade shows nothing, because sessions that began earlier were never
   recorded, and it says why and names `ws -List -All` and `ws -Show <n>`. Every
   row ends with `N shown · M hidden`, so what is left out is always counted.

2. **A hook, not the status line.** The generated settings now declare a
   `SessionStart` hook with no matcher, next to the status line command. It
   fires once per session start, so it records a session before the first answer
   rather than after it, and it records a session that was resumed, cleared,
   compacted or forked, because a person entering a session from a workstation
   window has put it in front of themselves. The status line cannot do this: it
   runs only after a response, and a session the person leaves before an answer
   would never be recorded. The hook script,
   `code/assets/claude/session-start.ps1`, is named by absolute path like the
   status line script, and the check that the status line script exists covers
   it too. A hook's stdout is added to the model's context, so the script
   prints nothing to stdout at all, and it exits zero whatever happens and
   reports the reason on stderr, so it can never block a session.

3. **A file the workstation owns.** The shown set is one file, one session id
   per line, named by the declared state next to `AgentStatus`:
   `workstation-generated/shown-sessions.txt`. It is written beside its final
   name and moved into place, never in part. Nothing is ever pruned: an id
   Claude has no transcript for yet may belong to a session that has only just
   started, and a store that cannot be read is no evidence that a session is
   gone, so the file keeps every id and the list leaves out those without a
   transcript. Nothing under the Claude configuration directory is written. An uninstall keeps the file, because it is not
   generated output: it records what the person chose, and removing it would
   silently hide everything again.

   **One lock for every write.** The set is replaced as a whole file by several
   processes at once: each hook runs in its own process, and so does each ws.
   Two writers that read the same set would each add their id and the second
   replacement would forget the first. So the hook, `-Show` and `-Hide` all
   read, change and replace the set under one exclusive lock: a sibling file,
   `shown-sessions.txt.lock`, opened with `FileShare.None` and retried for a
   short bounded time (two seconds, `WORKSTATION_SHOWN_LOCK_TIMEOUT_MS` in
   tests), with the temporary-file-and-rename write inside it. Readers open the file with `ReadWrite` and `Delete` sharing, and the replacement is retried for a second, because Windows refuses to replace a file another handle holds. The lock file is
   left in place. A hook that cannot get the lock exits zero, says why on
   stderr and leaves the session hidden; `-Show` and `-Hide` fail with an
   error and write nothing. The tests run real parallel pwsh processes.

   **The command names its path literally.** The generated hook and status line
   commands are run by a POSIX shell (Git Bash on Windows), where inside double
   quotes a `$` or a backtick still acts. The script path is therefore written
   in single quotes, with each single quote written as `'\''`, and a test runs
   the generated command through a shell from a directory named with `$`, a
   backtick, a space and a quote.

4. **Show and Hide.** `-Show` and `-Hide` take a number from the last list
   printed in this terminal, a session id, or nothing, which means the session of
   the agent pane in this window as the status file of
   [ADR 0008](0008-the-agent-pane-tells-the-status-bar-what-it-knows.md) last
   recorded it. Resolution of a number or an id is the resolution `-Session`
   uses, with the same errors. They are parameter sets that exclude each other
   and `-Session`, `-Project` and `-Agent`. The names say what the person sees:
   in the list or not. Pin, star and favourite say that a session matters more,
   which is a ranking, and this is a membership.

5. **Plan and Apply does not apply.** [ADR 0003](0003-plan-and-apply-are-mandatory-for-every-mutating-command.md)
   requires a plan and an apply for every command that changes the machine: its
   tools, its links, its files. Marking a session changes none of those. It is
   one line in a file that is the person's own list, it is undone by the opposite
   command, and the output of each action names exactly what changed. A plan
   would be longer than the action it guards. `-WhatIf` stays, as it does on
   everything that writes, and prints what would change without writing.

## Consequences

**The first list after the upgrade is empty.** It says why and what to do. Old
sessions are one `ws -Show` away, by number from `-List -All`.

**The no-argument form is only as exact as the status file.** That file is per
project, not per window, and it is written after the agent's first answer, so two
windows over one project share it and a fresh window must be answered once.
Both limits are in the usage guide. The number and id forms are always exact.

**Only Claude sessions are covered.** Other agents have no store the workstation
reads, so there is no list to filter.

**A claude started by hand never sees the generated settings.** Its sessions are
hidden until shown, which is the point of the default, and `ws -Show` is the
remedy.

**Nothing under the Claude configuration directory is touched.** This holds by
construction: the workstation's only writes are to its own file, and the
suite asserts that a snapshot of the store is unchanged after every action.

**A second hook is a second thing that can go missing.** The check reports the
script as missing, with the path, the same way it reports the status line script.

## Numbering

This is numbered 0009 because it is the next free number on `main` when it was
written. Open pull requests #22 and #24 carry ADRs under the same number. Whichever
is merged last is renumbered; the content does not depend on the number.

## References

- [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md), on
  why Claude's store is only read
- [ADR 0003](0003-plan-and-apply-are-mandatory-for-every-mutating-command.md),
  and why it does not govern this
- [ADR 0008](0008-the-agent-pane-tells-the-status-bar-what-it-knows.md), whose
  settings file and status file this extends
- `code/powershell/Workstation/Tests/Invoke-ShowQA.ps1`, which asserts every
  point above
