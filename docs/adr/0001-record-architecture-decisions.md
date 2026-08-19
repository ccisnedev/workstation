# 1. Record architecture decisions

Date: 2026-08-19

## Status

Accepted

## Context

This repository is the laboratory for a command that will eventually live in a
production tool. What gets ported is not the code — that will be rewritten in
another language — but the decisions the code embodies. A decision that exists
only as a shape in a script cannot be reviewed, argued with, or carried across.

## Decision

Architecture decisions are recorded here as ADRs, in the same format the MACSS
repository uses, so that a decision proven here can be ported by reference
rather than by rediscovery.

## Consequences

The port to `macss workstation` becomes a review of four ADRs plus a rewrite,
instead of an archaeology of someone's dotfiles.

## References

- Michael Nygard, *Documenting Architecture Decisions*
- `ccisnedev/macss`, `docs/adr/0001-record-architecture-decisions.md`
