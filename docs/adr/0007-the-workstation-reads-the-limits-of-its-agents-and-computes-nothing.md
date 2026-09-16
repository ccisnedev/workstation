# 7. The workstation reads the limits of its agents, and computes nothing

Date: 2026-09-15

## Status

Accepted

## Context

Every agent the workstation declares is sold as a flat plan with limits: so
much of a five-hour window, so much of a week, each resetting at a time the
vendor decides. The person at the keyboard has to know where those limits
stand, because the workstation is what spends them. On the day this was
written the Codex weekly limit had been reached in two days, from `codex exec`
runs launched inside Claude Code, and the only way to have known in time was to
open Codex and type `/status`.

Each vendor already publishes the numbers, but each in its own place. Claude
Code answers a request from the same endpoint its `/usage` screen reads,
with the token it keeps in its own credentials file, and reports a session
limit, a weekly limit, and a per-model weekly limit that mirrors the weekly one.
Codex writes a `rate_limits` block into every session rollout it records, one
block per pool it knows about, and there is no endpoint to ask; the last block
written is the last thing Codex knew.

What the numbers mean is not in question: a percentage of a limit, and when
that limit resets. What a percentage *costs* is. The plans are flat, so a
dollar figure for a week of use is not a fact about the account; it is an
estimate from a price list the vendor does not publish for the plan, and it
has been wrong every time it was tried here.

## Decision

The workstation shows how much of each declared agent's plan is used and
when each limit resets. It reads what the agents publish and computes nothing
from it.

1. **One command, one row per agent.** `Get-WorkstationUsage` returns a row
   per agent, and `ws -Usage` prints the same rows as a report. A row is the
   agent, the signed-in account, the plan, where the reading came from, when
   it was taken, and one entry per limit: a name, the percentage used, and the
   local time it resets.

2. **Percentages only.** No row, limit, or printed line carries a price,
   a cost, or a currency. The usage suite asserts it by name.

3. **An agent that publishes its limits says so in the declared state.** An
   agent entry may carry `UsageProvider`, which names how it is read:
   `claude` or `codex`. An agent without one is not read by default, and when
   named is a row whose `Source` is `unsupported`, so the answer to *why is
   opencode not listed* is on the page.

4. **Claude is read live; Codex is read from disk.** The Claude reading
   calls the endpoint its own `/usage` screen uses, with the access token in
   `<CLAUDE_CONFIG_DIR>/.credentials.json`, and is stamped with the moment it
   was taken. The Codex reading is the newest `rate_limits` block in the most
   recent rollouts under `<CODEX_HOME>/sessions`, chosen by its own timestamp
   and stamped with it, so a row can honestly say *read 2 h ago*. The Codex
   account and plan are the claims of the identity token in `auth.json`,
   decoded offline and never sent anywhere.

5. **A state that cannot be read is a row, never an error.** Not signed in,
   sign-in expired, endpoint unreachable, no Codex session recorded yet: each
   is a row whose `Source` is `unavailable` and whose `Reason` says which, and
   the command writes no error record. An expired token is not sent; it would
   only earn a refusal. An agent that is not declared at all is still an
   error, because that is a mistake in the command, not a state of the world.

6. **Nothing is written, and the token is never shown.** The command reads
   two vendor directories and one endpoint. It writes no file, refreshes no
   token, and the printed report never contains the credential it used. This
   is [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md)
   applied to reading: the workstation does not own those directories and
   leaves them as it found them.

7. **The scoped bar is not shown.** Claude's per-model weekly limit reported
   the same percentage and reset as the weekly limit throughout the period
   this was measured, so it would be a third line saying what the second line
   says. It is left out until it says something else.

8. **The network is behind a seam.** The one web request the module makes
   goes through a module-scope script block the usage suite replaces, so the
   suite calls nothing and reads no real credential, and the tests run in CI
   the way the session suite does.

## Consequences

**The workstation now reads credentials.** Only to present them to the
vendor that issued them, and only from the files the vendors keep for their
own use; but a reader of the module should know that one function opens
`.credentials.json` and one decodes `auth.json`, and the usage suite is where
that boundary is asserted.

**A Codex reading can be stale, and says so.** Codex publishes nothing on
request, so the row is as fresh as the last Codex session on this machine.
The age is on the report line. A machine that never ran Codex has no reading,
and the row says that rather than showing zero.

**The list of limits is whatever the vendor wrote.** Codex names its pools;
a pool that appears in a rollout is a limit on the row, prefixed with the
pool's name. A pool that has not been used recently is not in the recent
rollouts and is not shown. Nothing here decides which pools exist.

**Point 7 is a measurement, not a law.** The day the scoped bar diverges
from the weekly one, it should be shown, and the assertion that excludes it
is the one to change.

**What the model is, and how much of the context is used, are not here.**
Those are per-session facts an agent knows about itself, and belong to the
pane that runs it, not to a command that runs before anything is open. They
are the next slice, and the WezTerm status line is where they will be read.

## References

- [ADR 0002](0002-the-workstation-never-owns-what-it-did-not-create.md), on
  never owning what the workstation did not create, applied here to reading
- [ADR 0005](0005-architecture-and-preference-are-different-things.md), on
  seams for tests, of which `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are two more
- `code/powershell/Workstation/Tests/Invoke-UsageQA.ps1`, which asserts every
  point above
