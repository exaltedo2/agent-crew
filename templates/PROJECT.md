---
agent_crew_version: 0.3.1
# Extra globs (relative to the repo root) the lead may edit itself, besides .claude/team/**.
# Never effective for this file, .claude/settings*.json or hook scripts: those go through the coder.
lead_writable: []
# Globs the lead may commit and push straight to the main branch, without a pull request.
direct_to_main: []
# Optional: extra agents that may write only to .claude/team/reports/ (added to the built-in
# thinker, architect, reviewer, ui-reviewer, security-reviewer, perf-profiler).
report_only_agents: []
---

# Project profile

Written once by the `crew-bootstrap` skill, then kept short and true. Every agent reads it.
The lead reads it at the start of each session. On repository content this file wins over
the user-wide `~/.claude/team/USER.md`.

## Context

<!-- 3-6 lines: what the project is, what a finished deliverable looks like, who uses it. -->

## Commands

<!-- Verify commands, exact, with what a pass looks like. The coder runs ALL of them. -->

| Check | Command | Notes |
|---|---|---|
| tests | `<command>` | <how long, what to know> |
| lint | `<command>` | |

## Hazards

<!-- Things that broke before or that are easy to get wrong: processes to stop before
tests, shared ports or files, generated files that are committed, slow steps, risky
areas the reviewer must look at. One line each. -->

## Conventions

- Branches: `<feature/..., fix/...>`; never push to or merge into the default branch
  (unless a path matches `direct_to_main`).
- Pull requests: <who reviews and merges; what the body must say>.
- Commit messages: <language, trailers>.
- Language of code, comments and docs: <language>.

## Decision policy

- The team decides by itself: <routine design choices; record the chosen default in ...>.
- The user decides: <big or hard-to-undo choices, money, accounts, deleting things,
  changing the rules in this file>.

## Lead may run

<!-- Commands the lead may run itself instead of delegating (read-only by default):
git status/log/diff, gh pr view/list/checks, ... -->
